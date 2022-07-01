#!/usr/bin/env bash

#BRANCH=$BRANCH_NAME
#ENDPOINT_URL=$S3_ENDPOINT_URL
#DOC_DEST="$S3_UPLOAD_PATH/internals/${BRANCH_NAME}"
#
#aws s3 cp output/json "$DOC_DEST"/json --endpoint-url="$ENDPOINT_URL" --recursive --include "*" --exclude "*.jpg" --exclude "*.png" --exclude "*.svg"


set -xe
curl --fail --show-error \
    --data '{"update_key":"'"$INTERNALS_UPDATE_KEY"'"}' \
    --header "Content-Type: application/json" \
    --request POST "${INTERNALS_UPDATE_URL}"latest/