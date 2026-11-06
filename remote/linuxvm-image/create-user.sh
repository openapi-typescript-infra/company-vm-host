#!/bin/sh
# First-boot user provisioning hook for `container machine`. Intentionally a
# no-op: the runner user is baked into the image at build time, and the host
# account that creates the machine (_ghcontainer) must not be mirrored into
# the guest.
exit 0
