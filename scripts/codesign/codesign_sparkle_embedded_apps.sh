#!/usr/bin/env bash

# set to empty for debug builds
OTHER_CODE_SIGN_FLAGS="${OTHER_CODE_SIGN_FLAGS:-}"

set -exu

# codesign --deep is only 1 level deep. It misses Sparkle embedded app AutoUpdate
# this build phase script works around the issue

# Use specific certificate hash to avoid ambiguity when multiple "Apple Development" certs exist
# Override CODE_SIGN_IDENTITY if it's ambiguous
# Certificate: Apple Development: Christian Battaglia (P2P49QMQAR)
if [ "$CODE_SIGN_IDENTITY" = "Apple Development" ]; then
    SIGN_IDENTITY="1B78C2FAC584FFDF0BA955EFC8236F465E94B63F"
else
    SIGN_IDENTITY="$CODE_SIGN_IDENTITY"
fi

codesign --verbose --force --sign "$SIGN_IDENTITY" $OTHER_CODE_SIGN_FLAGS "${CODESIGNING_FOLDER_PATH}/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app"
