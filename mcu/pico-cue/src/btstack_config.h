/*
 * Intent: BTstack feature selection for pico-cue (RFC 0006 D3) — LE
 *         peripheral only: one connection, an ATT server with dynamic
 *         handlers, and the security manager for encrypted pairing.
 * Context: Sized for exactly what the Cue Ride Service needs; anything
 *          not enabled here is not compiled in, which keeps the radio
 *          stack's footprint off a board that also runs the kernel.
 */
#ifndef BTSTACK_CONFIG_H
#define BTSTACK_CONFIG_H

/* Port related features */
#define HAVE_ASSERT
#define HAVE_EMBEDDED_TIME_MS

/* BTstack features that can be enabled.
 * ENABLE_BLE is already set to 1 by pico_btstack_ble's CMake interface;
 * redefining it differently here is a -Werror macro-redefinition, so
 * defer to whatever the SDK set. */
#ifndef ENABLE_BLE
#define ENABLE_BLE
#endif
#define ENABLE_LE_PERIPHERAL
/* Deliberately NOT ENABLE_LE_SECURE_CONNECTIONS: LESC needs a P-256 ECC
 * backend this build does not configure, and legacy Just Works pairing
 * still encrypts the link — which is all RFC 0006 D3 claims ("LE
 * encryption via standard pairing where the stack permits"). The stated
 * residual risk there (segment ids are route-reconstructable) is
 * unchanged either way, since neither mode authenticates the peer. */
#define ENABLE_LOG_INFO
#define ENABLE_LOG_ERROR
#define ENABLE_PRINTF_HEXDUMP

/* ATT long writes carry a STEP that exceeds the negotiated MTU
 * (max 302 B, RFC 0006 D3) — required when a central grants a small MTU. */
#define ENABLE_ATT_DELAYED_RESPONSE

/* BTstack configuration. buffers, sizes, ... */
#define HCI_OUTGOING_PRE_BUFFER_SIZE 4
#define HCI_ACL_PAYLOAD_SIZE (255 + 4)
#define HCI_ACL_CHUNK_SIZE_ALIGNMENT 4
#define MAX_NR_GATT_CLIENTS 0
#define MAX_NR_HCI_CONNECTIONS 1
#define MAX_NR_L2CAP_SERVICES 0
#define MAX_NR_L2CAP_CHANNELS 0
#define MAX_NR_SM_LOOKUP_ENTRIES 3
#define MAX_NR_WHITELIST_ENTRIES 1
#define MAX_NR_LE_DEVICE_DB_ENTRIES 1

/* Prepare-write queue for ATT long writes: a max 302-byte STEP arrives
 * in (MTU-5)-byte chunks. iOS negotiates MTU 255 and needs 2 fragments,
 * but a central that never negotiates sits at the BLE minimum MTU of 23
 * and needs 17 — so the queue is sized for the worst case rather than
 * the expected one. Undersizing it fails dense-event steps only, and
 * only on low-MTU centrals: a nasty, intermittent-looking bug for the
 * sake of a few hundred bytes of RAM. */
#define MAX_NR_ATT_PREPARE_WRITE_QUEUE 20
#define ATT_PREPARE_WRITE_BUFFER_SIZE 512

/* Link Key DB and LE Device DB using TLV on top of Flash Sector interface */
#define NVM_NUM_DEVICE_DB_ENTRIES 1
#define NVM_NUM_LINK_KEYS 1

/* We don't give btstack a malloc, so use a fixed-size ATT DB. */
#define MAX_ATT_DB_SIZE 512

#define MAX_NR_CONTROLLER_ACL_BUFFERS 3
#define MAX_NR_CONTROLLER_SCO_PACKETS 0

#endif /* BTSTACK_CONFIG_H */
