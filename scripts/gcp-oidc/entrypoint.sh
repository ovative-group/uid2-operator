#!/bin/sh
#
# This script must be compatible with Ash (provided in eclipse-temurin Docker image) and Bash

# -- set API tokens
if [ -z "${API_TOKEN}" ]; then
  echo "API_TOKEN cannot be empty"
  exit 1
fi
export core_api_token="${API_TOKEN}"
export optout_api_token="${API_TOKEN}"

# -- locate config file
if [ -z "${DEPLOYMENT_ENVIRONMENT}" ]; then
  echo "DEPLOYMENT_ENVIRONMENT cannot be empty"
  exit 1
fi
if [ "${DEPLOYMENT_ENVIRONMENT}" != 'prod' -a "${DEPLOYMENT_ENVIRONMENT}" != 'integ' ]; then
  echo "Unrecognized DEPLOYMENT_ENVIRONMENT ${DEPLOYMENT_ENVIRONMENT}"
  exit 1
fi

TARGET_CONFIG="/app/conf/${DEPLOYMENT_ENVIRONMENT}-uid2-config.json"
if [ ! -f "${TARGET_CONFIG}" ]; then
  echo "Unrecognized config ${TARGET_CONFIG}"
  exit 1
fi

FINAL_CONFIG="/tmp/final-config.json"
echo "-- copying ${TARGET_CONFIG} to ${FINAL_CONFIG}"
cp ${TARGET_CONFIG} ${FINAL_CONFIG}
if [ $? -ne 0 ]; then
  echo "Failed to create ${FINAL_CONFIG} with error code $?"
  exit 1
fi

# -- start operator
echo "-- starting java application"
java \
    -XX:MaxRAMPercentage=95 -XX:-UseCompressedOops -XX:+PrintFlagsFinal \
    -Djava.security.egd=file:/dev/./urandom \
    -Dvertx.logger-delegate-factory-class-name=io.vertx.core.logging.SLF4JLogDelegateFactory \
    -Dlogback.configurationFile=${LOGBACK_CONF} \
    -Dvertx-config-path=${FINAL_CONFIG} \
    -jar ${JAR_NAME}-${JAR_VERSION}.jar