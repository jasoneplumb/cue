/*
 * Intent: Implementation of the BTstack transport (see header).
 * Pattern: ATT write callbacks decode nothing themselves — they hand the
 *          raw payload to cue_session and translate its CueSessionStatus
 *          into an ATT error, so the protocol has exactly one
 *          implementation and it is the host-tested one.
 */
#ifdef PICO_BUILD

#include "cue_ble.h"

#include <string.h>

#include "btstack.h"
#include "pico/stdlib.h"
#include "btstack_tlv_flash_bank.h"
#include "ble/le_device_db_tlv.h"
#include "pico/btstack_flash_bank.h"
#include "pico/cyw43_arch.h"

#include "cue_actuator.h"
#include "cue_power.h"
#include "cue_session.h"
#include "cue_wire.h"

#include "cue_gatt.h" /* generated from cue.gatt by compile_gatt.py */

static CueSession session;
static hci_con_handle_t con_handle = HCI_CON_HANDLE_INVALID;
static uint16_t decision_cccd;
static uint16_t status_cccd;
static uint16_t control_cccd;

/* Pending DECISION notify. One in flight is enough: steps arrive at 1 Hz
 * and each is answered before the next, so this can never queue up. */
static uint8_t pending_decision[CUE_WIRE_DECISION_REPORT_SIZE];
static bool decision_pending;

/* Pending CONTROL indication (session acks). */
static uint8_t pending_control[CUE_CTRL_MAX_RESPONSE_SIZE];
static uint16_t pending_control_len;
static bool control_pending;

/* Last VSYS sample and supply state, refreshed together from the main
 * loop (see cue_ble_poll). Together, because millivolts without the
 * supply they were measured against are not evidence — on this carrier
 * VSYS is unpowered whenever USB is out (#165) — and sampling them at
 * different moments would let the sidecar pair a battery voltage with a
 * USB flag across a cable pull. */
static uint16_t battery_mv;
static uint8_t supply = CUE_POWER_SUPPLY_UNKNOWN;
static uint32_t battery_sampled_ms;
static bool battery_sampled;

/* Set once the controller actually reaches HCI_STATE_WORKING — NOT when
 * hci_power_control() returns, which is asynchronous and tells us only
 * that the request was made. The distinction is the whole value of this
 * flag: it is what the status LED and the wired DIAG report, and a flag
 * set optimistically would report "up" for a radio that never came up. */
static bool radio_up;

/* Set once cyw43_arch_init() succeeded. Separate from radio_up because it
 * answers a different question: whether the VSYS read may take the cyw43
 * lock. That is true as soon as the driver is initialised, well before
 * the controller finishes coming up. */
static bool cyw43_ready;

static btstack_packet_callback_registration_t hci_callback;
static btstack_context_callback_registration_t decision_callback;
static btstack_context_callback_registration_t control_callback;

/* Exactly 31 bytes — the legacy advertising limit, with no room spare.
 * Adding anything here means dropping something or moving it to the scan
 * response. */
static const uint8_t adv_data[] = {
    /* Flags: LE General Discoverable, BR/EDR not supported */
    0x02, BLUETOOTH_DATA_TYPE_FLAGS, 0x06,
    /* The Cue Ride Service UUID (85BF0001-C87E-4346-8A6C-440B3E57F451),
     * little-endian as the air format requires — reversed relative to how
     * it reads in cue_wire.h and the .gatt file.
     *
     * NOT optional, despite the phone also matching on the name: iOS
     * cannot scan without a service filter while backgrounded, and rides
     * run with the phone pocketed and the screen locked. Without this the
     * central finds nothing the moment the app leaves the foreground —
     * which is most of every ride. */
    0x11, BLUETOOTH_DATA_TYPE_COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS,
    0x51, 0xF4, 0x57, 0x3E, 0x0B, 0x44, 0x6C, 0x8A,
    0x46, 0x43, 0x7E, 0xC8, 0x01, 0x00, 0xBF, 0x85,
    /* Complete local name */
    0x09, BLUETOOTH_DATA_TYPE_COMPLETE_LOCAL_NAME, 'p', 'i', 'c', 'o', '-', 'c',
    'u', 'e',
};

/* The advertisement must fit the 31-byte legacy limit, and the UUID above
 * must be the little-endian image of CUE_GATT_UUID_SERVICE. The length is
 * checked here; the bytes were derived from that string rather than typed
 * (a hand-transcribed nibble already cost one debugging round). */
_Static_assert(sizeof(adv_data) == 31,
               "advertisement must be exactly 31 bytes — over the limit it is "
               "rejected, under it something was dropped");

/* --- notification senders -------------------------------------------------- */

static void send_decision(void *context) {
  (void)context;
  if (!decision_pending || con_handle == HCI_CON_HANDLE_INVALID) {
    return;
  }
  decision_pending = false;
  att_server_notify(con_handle, ATT_CHARACTERISTIC_85BF0004_C87E_4346_8A6C_440B3E57F451_01_VALUE_HANDLE,
                    pending_decision, sizeof(pending_decision));
}

static void send_control(void *context) {
  (void)context;
  if (!control_pending || con_handle == HCI_CON_HANDLE_INVALID) {
    return;
  }
  control_pending = false;
  att_server_indicate(con_handle, ATT_CHARACTERISTIC_85BF0002_C87E_4346_8A6C_440B3E57F451_01_VALUE_HANDLE,
                      pending_control, pending_control_len);
}

static void queue_decision(const uint8_t *report) {
  memcpy(pending_decision, report, sizeof(pending_decision));
  decision_pending = true;
  decision_callback.callback = &send_decision;
  decision_callback.context = NULL;
  att_server_request_to_send_notification(&decision_callback, con_handle);
}

static void queue_control(const uint8_t *response, uint16_t len) {
  if (len > sizeof(pending_control)) {
    return;
  }
  memcpy(pending_control, response, len);
  pending_control_len = len;
  control_pending = true;
  control_callback.callback = &send_control;
  control_callback.context = NULL;
  att_server_request_to_send_indication(&control_callback, con_handle);
}

/* --- ATT callbacks --------------------------------------------------------- */

/* CueSessionStatus -> ATT error. A refused write must fail the ATT
 * operation, not succeed silently: the phone's streamer uses the
 * write response to decide whether it needs to resync (RFC 0006 D4). */
static uint8_t att_error_for(CueSessionStatus st) {
  switch (st) {
    case CUE_SESSION_OK:
      return 0;
    case CUE_SESSION_ERR_LENGTH:
      return ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LENGTH;
    case CUE_SESSION_ERR_STATE:
    case CUE_SESSION_ERR_SEQ_GAP:
      /* "Try again after resyncing" — distinct from a malformed write. */
      return ATT_ERROR_UNLIKELY_ERROR;
    case CUE_SESSION_ERR_FLAGS:
    case CUE_SESSION_ERR_EVENTS:
    case CUE_SESSION_ERR_OPCODE:
    default:
      return ATT_ERROR_VALUE_NOT_ALLOWED;
  }
}

static uint16_t att_read_callback(hci_con_handle_t connection_handle,
                                  uint16_t attribute_handle, uint16_t offset,
                                  uint8_t *buffer, uint16_t buffer_size) {
  (void)connection_handle;
  if (attribute_handle ==
      ATT_CHARACTERISTIC_85BF0005_C87E_4346_8A6C_440B3E57F451_01_VALUE_HANDLE) {
    uint8_t status[CUE_WIRE_STATUS_SIZE];
    cue_wire_put_u16(status + 0, 0x0001u); /* fw version, packed major.minor */
    status[2] = session.state;
    status[CUE_WIRE_STATUS_SUPPLY_OFFSET] = supply;
    /* Cached, never sampled here: reading VSYS borrows GPIO29 back from
     * the radio (see cue_power.c), and doing that inside an ATT callback
     * would take the pin while the stack that owns it is mid-callback.
     * cue_ble_poll() refreshes it from the main loop. 0 means "not yet
     * sampled" rather than a fabricated voltage. */
    cue_wire_put_u16(status + 3, battery_mv);
    return att_read_callback_handle_blob(status, sizeof(status), offset, buffer,
                                         buffer_size);
  }
  return 0;
}

/* Long-write reassembly (RFC 0006 D3). A full 16-event STEP is 302 B,
 * which exceeds the ATT payload (MTU-3) on any MTU below 305 — iOS
 * commonly grants 255, so the dense-event case ALWAYS arrives as an ATT
 * prepare/execute sequence. Each prepare lands here with
 * ATT_TRANSACTION_MODE_ACTIVE and its own offset; the payload is only
 * complete at EXECUTE. Handing a fragment straight to cue_session would
 * reject it as a length error, so fragments accumulate here first. */
static uint8_t assembly[CUE_WIRE_STEP_MAX_SIZE];
static uint16_t assembly_len;
static bool assembly_overflow;
/* BTstack signals EXECUTE with attribute_handle == 0 (att_db.c), so the
 * target characteristic has to be remembered from the fragments. */
static uint16_t assembly_handle;

static void assembly_reset(void) {
  assembly_len = 0;
  assembly_overflow = false;
  assembly_handle = 0;
}

static int assembly_append(uint16_t attribute_handle, uint16_t offset,
                           const uint8_t *buffer, uint16_t buffer_size) {
  if (assembly_handle == 0) {
    assembly_handle = attribute_handle;
  } else if (assembly_handle != attribute_handle) {
    /* One queued write spanning two characteristics is not something
     * this protocol ever produces; refuse rather than interleave. */
    assembly_overflow = true;
    return ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LENGTH;
  }
  if ((size_t)offset + buffer_size > sizeof(assembly)) {
    /* Fail fast: the central learns on this fragment instead of after
     * queueing the rest, and per spec it then cancels the transaction,
     * which resets the buffer. The flag is still set so the VALIDATE and
     * EXECUTE arms refuse too — defensive only, since a conforming
     * central never reaches them after this error, but the buffer must
     * never be dispatchable while it holds a partial payload. */
    assembly_overflow = true;
    return ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LENGTH;
  }
  memcpy(assembly + offset, buffer, buffer_size);
  uint16_t end = (uint16_t)(offset + buffer_size);
  if (end > assembly_len) {
    assembly_len = end;
  }
  return 0;
}

static int att_write_callback(hci_con_handle_t connection_handle,
                              uint16_t attribute_handle,
                              uint16_t transaction_mode, uint16_t offset,
                              uint8_t *buffer, uint16_t buffer_size);

/* Dispatch a fully-assembled payload to the session. */
static int dispatch_write(hci_con_handle_t connection_handle,
                          uint16_t attribute_handle, uint8_t *payload,
                          uint16_t payload_len);

static int att_write_callback(hci_con_handle_t connection_handle,
                              uint16_t attribute_handle,
                              uint16_t transaction_mode, uint16_t offset,
                              uint8_t *buffer, uint16_t buffer_size) {
  switch (transaction_mode) {
    case ATT_TRANSACTION_MODE_ACTIVE:
      /* One fragment of a queued write — buffer it, decide nothing. */
      return assembly_append(attribute_handle, offset, buffer, buffer_size);
    case ATT_TRANSACTION_MODE_CANCEL:
      assembly_reset();
      return 0;
    case ATT_TRANSACTION_MODE_VALIDATE:
      return assembly_overflow ? ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LENGTH : 0;
    case ATT_TRANSACTION_MODE_EXECUTE: {
      if (assembly_overflow) {
        assembly_reset();
        return ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LENGTH;
      }
      /* attribute_handle is 0 here; the real target came from the
       * fragments. assembly_reset() clears the length but not the
       * buffer contents, so dispatching from it after the reset is
       * safe — and keeps the reset on every exit path. */
      uint16_t handle = assembly_handle;
      uint16_t len = assembly_len;
      assembly_reset();
      if (handle == 0 || len == 0) {
        return 0; /* execute with nothing queued */
      }
      return dispatch_write(connection_handle, handle, assembly, len);
    }
    case ATT_TRANSACTION_MODE_NONE:
    default:
      /* Ordinary single-PDU write: the common 1 Hz case, where a step
       * carries 0-3 events and fits comfortably. */
      return dispatch_write(connection_handle, attribute_handle, buffer,
                            buffer_size);
  }
}

static int dispatch_write(hci_con_handle_t connection_handle,
                          uint16_t attribute_handle, uint8_t *buffer,
                          uint16_t buffer_size) {
#ifdef CUE_BLE_TRACE
  printf("[ble] write handle=0x%04x len=%u\n", attribute_handle, buffer_size);
#endif
  /* CCCD writes: remember subscriptions. A CCCD value is two bytes, but
   * that is checked here rather than assumed — the link is unauthenticated
   * in this phase, so a non-conformant or hostile central can write one
   * byte, and little_endian_read_16 would then read past the buffer. */
  bool is_cccd =
      attribute_handle ==
          ATT_CHARACTERISTIC_85BF0004_C87E_4346_8A6C_440B3E57F451_01_CLIENT_CONFIGURATION_HANDLE ||
      attribute_handle ==
          ATT_CHARACTERISTIC_85BF0005_C87E_4346_8A6C_440B3E57F451_01_CLIENT_CONFIGURATION_HANDLE ||
      attribute_handle ==
          ATT_CHARACTERISTIC_85BF0002_C87E_4346_8A6C_440B3E57F451_01_CLIENT_CONFIGURATION_HANDLE;
  if (is_cccd) {
    if (buffer_size < 2) {
      return ATT_ERROR_INVALID_ATTRIBUTE_VALUE_LENGTH;
    }
    uint16_t value = little_endian_read_16(buffer, 0);
    if (attribute_handle ==
        ATT_CHARACTERISTIC_85BF0004_C87E_4346_8A6C_440B3E57F451_01_CLIENT_CONFIGURATION_HANDLE) {
      decision_cccd = value;
    } else if (attribute_handle ==
               ATT_CHARACTERISTIC_85BF0005_C87E_4346_8A6C_440B3E57F451_01_CLIENT_CONFIGURATION_HANDLE) {
      status_cccd = value;
    } else {
      control_cccd = value;
    }
    return 0;
  }

  if (attribute_handle ==
      ATT_CHARACTERISTIC_85BF0002_C87E_4346_8A6C_440B3E57F451_01_VALUE_HANDLE) {
    con_handle = connection_handle;
    uint8_t response[CUE_CTRL_MAX_RESPONSE_SIZE];
    size_t response_len = 0;
    CueTestCueRequest test_cue;
    CueSessionStatus st = cue_session_handle_control(
        &session, buffer, buffer_size, response, sizeof(response),
        &response_len, &test_cue);
    if (response_len > 0) {
      queue_control(response, (uint16_t)response_len);
    }
    if (test_cue.fire) {
      /* Actuator only — a test cue never touches the kernel, so it cannot
       * appear in the decision stream or perturb an FR-004 budget. The
       * index was range-checked by cue_session (RFC 0006 D7). */
      (void)cue_actuator_fire(test_cue.pattern);
    }
    return att_error_for(st);
  }

  if (attribute_handle ==
      ATT_CHARACTERISTIC_85BF0003_C87E_4346_8A6C_440B3E57F451_01_VALUE_HANDLE) {
    con_handle = connection_handle;
    /* Start the clock before the kernel runs: what the D5 gate wants to
     * know is how long after the step arrived the rider heard anything,
     * so the kernel step belongs inside the measurement, not outside it. */
    uint32_t arrived_us = time_us_32();
    uint8_t report[CUE_WIRE_DECISION_REPORT_SIZE];
    size_t report_len = 0;
    bool actuate = false;
    CueSessionStatus st =
        cue_session_handle_step(&session, buffer, buffer_size, report,
                                sizeof(report), &report_len, &actuate);
    if (actuate) {
      /* Every HEAD_UP the kernel decides, rendered as the selected
       * candidate pattern. Catch-up steps never reach here — cue_session
       * clears `actuate` for them, because a burst of stale cues after a
       * link gap is the noisy cueing NFR-001 forbids. */
      (void)cue_actuator_fire((uint8_t)CUE_PATTERN_SELECTED);
      /* Record the measured delay into the report the session built with a
       * placeholder 0 (it owns no clock by design) — and into its cache,
       * so a retried step does not answer with a fabricated zero. Done
       * BEFORE queueing so the phone's sidecar gets the real number. */
      uint32_t delay_us = time_us_32() - arrived_us;
      cue_session_record_actuation_delay_us(
          &session, report,
          (uint16_t)(delay_us > CUE_WIRE_ACTUATION_DELAY_US_MAX
                         ? CUE_WIRE_ACTUATION_DELAY_US_MAX
                         : delay_us));
    }
    if (report_len == sizeof(report) && decision_cccd != 0) {
      queue_decision(report);
    }
    return att_error_for(st);
  }

  return 0;
}

/* --- HCI events ------------------------------------------------------------ */

static void hci_packet_handler(uint8_t packet_type, uint16_t channel,
                               uint8_t *packet, uint16_t size) {
  (void)channel;
  (void)size;
  if (packet_type != HCI_EVENT_PACKET) {
    return;
  }
#ifdef CUE_BLE_TRACE
  {
    uint8_t t = hci_event_packet_get_type(packet);
    /* Security-manager and encryption events are the ones that matter
     * when a central reports insufficient encryption. */
    if (t == HCI_EVENT_ENCRYPTION_CHANGE || t == SM_EVENT_JUST_WORKS_REQUEST ||
        t == SM_EVENT_PAIRING_STARTED || t == SM_EVENT_PAIRING_COMPLETE ||
        t == SM_EVENT_REENCRYPTION_STARTED || t == SM_EVENT_REENCRYPTION_COMPLETE ||
        t == SM_EVENT_IDENTITY_RESOLVING_FAILED || t == ATT_EVENT_MTU_EXCHANGE_COMPLETE) {
      printf("[ble] event 0x%02x\n", t);
    }
  }
#endif
  switch (hci_event_packet_get_type(packet)) {
    case BTSTACK_EVENT_STATE:
      if (btstack_event_state_get_state(packet) == HCI_STATE_WORKING) {
        /* The controller is genuinely up only here. Until this arrives
         * the status LED stays red, which is the honest reading of a
         * device that cannot yet be reached. */
        radio_up = true;
        gap_advertisements_enable(1);
      }
      break;
    case HCI_EVENT_DISCONNECTION_COMPLETE:
      /* Per-connection state is cleared here: CCCDs, pending sends, and the
       * ATT long-write assembly buffer, none of which mean anything once
       * the link is gone. Deliberately does NOT reset the session: kernel
       * state belongs to the ride, not the connection, so the phone can
       * reconnect and SESSION_RESUME rather than re-streaming everything
       * (RFC 0006 D4). */
      con_handle = HCI_CON_HANDLE_INVALID;
      decision_cccd = 0;
      status_cccd = 0;
      control_cccd = 0;
      decision_pending = false;
      control_pending = false;
      assembly_reset();
      gap_advertisements_enable(1);
      break;
    case HCI_EVENT_META_GAP:
      if (hci_event_gap_meta_get_subevent_code(packet) ==
          GAP_SUBEVENT_LE_CONNECTION_COMPLETE) {
        con_handle = gap_subevent_le_connection_complete_get_connection_handle(packet);
        /* NOTE: this link is NOT encrypted — see cue_gatt.gatt. The ride
         * characteristics do not carry ENCRYPTION_KEY_SIZE_16 yet, so
         * nothing here or in the ATT layer requires a secure link.
         *
         * Deliberately NOT calling sm_request_pairing() either: sending a
         * Security Request the instant the link comes up made
         * CoreBluetooth drop the connection mid service-discovery
         * (observed on macOS). When encryption is turned on, the intended
         * trigger is the ATT insufficient-encryption error on the first
         * CONTROL/STEP write, which pairs on demand and leaves discovery
         * unencumbered. Tracked for Phase B3 (RFC 0006 D3, NFR-005). */
      }
      break;
    default:
      break;
  }
}

/* --- lifecycle -------------------------------------------------------------- */

bool cue_ble_init(void) {
  if (cyw43_arch_init() != 0) {
    return false;
  }
  cyw43_ready = true;
  /* Power sensing is radio-gated too, and on the DRIVER exactly as the
   * VSYS sample below is — not on the controller coming up. Told from
   * here rather than from main() so the one fact has one owner: the
   * alternative gates on cue_ble_init()'s return, which is a stricter
   * condition and would report "unknown supply" on a board whose driver
   * is fine and whose controller merely failed. */
  cue_power_set_radio_available(true);
  /* Same fact, second consumer: the actuator's state is reached from both
   * the main loop and the ATT callbacks this driver will dispatch from a
   * low-priority IRQ, so from here on it must serialise on the cyw43 lock
   * (#18). Told before hci_power_control() below, so it is true before any
   * connection exists to produce an ATT write. */
  cue_actuator_set_lock_available();
  cue_session_init(&session);

  l2cap_init();

  /* Bonds must outlive a reboot. Without persistent storage the Pico
   * forgets its keys on every power cycle while the phone remembers
   * them, so the phone would try to encrypt with a key the Pico no
   * longer has and the link would drop — on every ride, not just after
   * a reflash. The bank sits at the top of flash, which a UF2 load of
   * this image does not erase, so bonds also survive firmware updates. */
  static btstack_tlv_flash_bank_t tlv_context;
  const btstack_tlv_t *tlv_impl = btstack_tlv_flash_bank_init_instance(
      &tlv_context, pico_flash_bank_instance(), NULL);
  btstack_tlv_set_instance(tlv_impl, &tlv_context);
  le_device_db_tlv_configure(tlv_impl, &tlv_context);

  /* Just Works bonding is configured and its keys now persist, but the
   * ride characteristics do NOT yet require encryption — see the note in
   * cue_gatt.gatt. Do not describe this link as encrypted until those
   * properties are set and verified against the iPhone. */
  sm_init();
  sm_set_io_capabilities(IO_CAPABILITY_NO_INPUT_NO_OUTPUT);
  sm_set_authentication_requirements(SM_AUTHREQ_BONDING);

  att_server_init(profile_data, att_read_callback, att_write_callback);

  hci_callback.callback = &hci_packet_handler;
  hci_add_event_handler(&hci_callback);
  att_server_register_packet_handler(&hci_packet_handler);

  uint16_t adv_int_min = 0x0030; /* 30 ms — fast discovery at ride start */
  uint16_t adv_int_max = 0x0060;
  bd_addr_t null_addr;
  memset(null_addr, 0, sizeof(null_addr));
  gap_advertisements_set_params(adv_int_min, adv_int_max, 0, 0, null_addr, 0x07,
                                0x00);
  gap_advertisements_set_data(sizeof(adv_data), (uint8_t *)adv_data);

  /* Asynchronous: radio_up is set by the BTSTACK_EVENT_STATE handler when
   * the controller reports HCI_STATE_WORKING, not here. */
  hci_power_control(HCI_POWER_ON);
  return true;
}

/* VSYS changes on a timescale of minutes; sampling it more often than
 * this only costs the radio its clock pin more often. */
#define CUE_BATTERY_REFRESH_MS 10000u

void cue_ble_poll(void) {
  /* BTstack itself is serviced by the pico-sdk async_context. What this
   * pumps is the work that must NOT happen inside an ATT callback. */
  uint32_t now = to_ms_since_boot(get_absolute_time());

  /* Gated on the DRIVER being initialised, not on the controller being
   * up: the VSYS read takes the cyw43 lock, which means nothing coherent
   * if cyw43_arch_init() never succeeded, but it is perfectly safe while
   * the controller is still coming up. */
  if (cyw43_ready &&
      (!battery_sampled || now - battery_sampled_ms >= CUE_BATTERY_REFRESH_MS)) {
    /* Main-loop context, so borrowing GPIO29 back from the CYW43 is safe
     * here in a way it is not inside a callback (see cue_power.c). */
    cue_power_sample(&battery_mv, &supply);
    battery_sampled_ms = now;
    battery_sampled = true;
  }

  /* The LEDs say what the link is doing whenever no cue is playing. A
   * radio that never came up stays red: silence from a device whose whole
   * job is to make itself noticed must not look like idle. */
  if (!radio_up) {
    cue_actuator_set_status(CUE_ACT_STATUS_ERROR);
  } else {
    cue_actuator_set_status(con_handle != HCI_CON_HANDLE_INVALID
                                ? CUE_ACT_STATUS_CONNECTED
                                : CUE_ACT_STATUS_ADVERTISING);
  }
}

bool cue_ble_is_connected(void) {
  return con_handle != HCI_CON_HANDLE_INVALID && decision_cccd != 0;
}

bool cue_ble_is_up(void) { return radio_up; }

bool cue_ble_decision_pending(uint16_t *seq_out) {
  if (decision_pending && seq_out != NULL) {
    *seq_out = cue_wire_get_u16(pending_decision);
  }
  return decision_pending;
}

bool cue_ble_has_central(void) {
  return con_handle != HCI_CON_HANDLE_INVALID;
}

#endif /* PICO_BUILD */
