#!/usr/bin/env bash


BRANCH=$BRANCH_NAME
DOC_DEST="$S3_UPLOAD_PATH/internals/${BRANCH_NAME}"
CHECK_KEY="doc-builds/internals/${BRANCH_NAME}/json/_build_ru/json/toctree.fjson"

aws s3api head-object --bucket ${S3_BUCKET} --key ${CHECK_KEY} --endpoint-url="$ENDPOINT_URL" || not_exist=true
if [ $not_exist ]; then
  echo "toctree.json does not exist"
else
  echo "found toctree.json, remove the branch from s3 location"
  aws s3 rm "$DOC_DEST"/json --endpoint-url="$ENDPOINT_URL" --recursive
fi

aws s3 cp build/json "$DOC_DEST"/json --endpoint-url="$ENDPOINT_URL" --recursive --include "*" --exclude "*.jpg" --exclude "*.png" --exclude "*.svg"
