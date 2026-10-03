# Provisioning

The one-time Xcode setup to get the app onto a physical iPhone and Apple Watch.

1. **Signing.** Xcode → Settings → Accounts → add your Apple ID. In the
   project, select the Cue target → Signing & Capabilities → check
   "Automatically manage signing" and pick your Personal Team; repeat for
   the watch target. The bundle IDs (`com.jasoneplumb.cue` /
   `.watchkitapp`) are already set. A personal team's provisioning profile
   expires every 7 days, after which the app stops launching until you
   re-run from Xcode: fine for the first ride or two, but the $99/yr
   Developer Program (year-long profiles) is worth it before a 10-ride
   study.
2. **Devices.** Plug in the iPhone (or pair over Wi-Fi) and enable
   Developer Mode (Settings → Privacy & Security → Developer Mode,
   reboots); do the same on the watch. On first install, trust the
   developer certificate on-device (Settings → General → VPN & Device
   Management).
3. **Run.** Select the Cue scheme with the iPhone as destination and hit
   Run; the watch app installs alongside the phone. Grant location
   permission when prompted (the usage string is already in the build
   settings).
4. **Two capabilities not yet enabled**, which is why the ride screen
   currently says "keep the screen on":
   - **Background location (phone).** Cue target → Signing & Capabilities
     → + Capability → Background Modes → Location updates. This needs a
     matching code change (`allowsBackgroundLocationUpdates = true`),
     deliberately not set yet because enabling it without the capability
     crashes. Until both land, rides require the screen on and the phone
     mounted or unlocked in a pocket.
   - **Watch runtime session.** The watch's "Ride mode" toggle uses
     `WKExtendedRuntimeSession`, which needs its session type declared
     under the watch target's Background Modes. Apple's extended-runtime
     types (self-care, mindfulness, etc.) are all an awkward fit for a
     bike ride; a workout session (the HealthKit capability named in the
     RFC) is the better fit and is the remaining decision to make at
     provisioning time. Either option keeps the watch awake enough to
     deliver the tap.
5. **Region import.** Once running, fetch the loop's Overpass extract (per
   `osm_tag_audit.sh`), AirDrop or save the JSON to the phone, and load it
   via the app's "Import region…" picker. It parses, scores, and caches,
   then the Start Ride button goes live.
