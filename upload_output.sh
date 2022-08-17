#!/usr/bin/env bash

set -xe -o pipefail -o nounset

DOC_DEST="$S3_UPLOAD_PATH/internals/${DEPLOYMENT_NAME}"
# version in doc project and scripts is always 'latest'
# for both prod and test server, because internals
# is a single-version project.
DOC_VERSION=latest
# directory in the S3 bucket: latest or test.
CHECK_KEY="doc-builds/internals/${DEPLOYMENT_NAME}/json/_build_en/json/toctree.fjson"

not_exist=false
aws s3api head-object --bucket ${S3_BUCKET} --key ${CHECK_KEY} --endpoint-url="${S3_ENDPOINT_URL}" || not_exist=true
if [ $not_exist ]; then
  echo "toctree.json does not exist"
else
  echo "found toctree.json, remove the branch from s3 location"
  aws s3 rm "${DOC_DEST}"/json --endpoint-url="${S3_ENDPOINT_URL}" --recursive
fi

aws s3 cp build/json "${DOC_DEST}"/json/_build_en/json --endpoint-url="${S3_ENDPOINT_URL}" --recursive --include "*" --exclude "*.jpg" --exclude "*.png" --exclude "*.svg"
