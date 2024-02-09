#!/bin/bash -eufx

set -o pipefail
ulimit -n 65536

# -- setup loopback device
echo "Setting up loopback device..."
ifconfig lo 127.0.0.1

# -- start vsock proxy
echo "Starting vsock proxy..."
/app/vsockpx --config /app/proxies.nitro.yaml --daemon --workers $(( $(nproc) * 2 )) --log-level 3

# -- load env vars via proxy
echo "Loading env vars via proxy..."

if [ "${IDENTITY_SCOPE}" = "UID2" ]; then
  USER_DATA=$(curl -s -x socks5h://127.0.0.1:3305 http://169.254.169.254/latest/user-data)
  UID2_CONFIG_SECRET_KEY=$([[ "$(echo "${USER_DATA}" | grep UID2_CONFIG_SECRET_KEY=)" =~ ^export\ UID2_CONFIG_SECRET_KEY=\"(.*)\"$ ]] && echo "${BASH_REMATCH[1]}" || echo "uid2-operator-config-key")
  CORE_BASE_URL=$([[ "$(echo "${USER_DATA}" | grep CORE_BASE_URL=)" =~ ^export\ CORE_BASE_URL=\"(.*)\"$ ]] && echo "${BASH_REMATCH[1]}" || echo "")
  OPTOUT_BASE_URL=$([[ "$(echo "${USER_DATA}" | grep OPTOUT_BASE_URL=)" =~ ^export\ OPTOUT_BASE_URL=\"(.*)\"$ ]] && echo "${BASH_REMATCH[1]}" || echo "")
  ENFORCE_HTTPS=$([[ "$(echo "${USER_DATA}" | grep ENFORCE_HTTPS=)" =~ ^export\ ENFORCE_HTTPS=\"(.*)\"$ ]] && echo "${BASH_REMATCH[1]}" || echo "false")
elif [ "${IDENTITY_SCOPE}" = "EUID" ]; then
  USER_DATA=$(curl -s -x socks5h://127.0.0.1:3305 http://169.254.169.254/latest/user-data)
  UID2_CONFIG_SECRET_KEY=$([[ "$(echo "${USER_DATA}" | grep UID2_CONFIG_SECRET_KEY=)" =~ ^export\ UID2_CONFIG_SECRET_KEY=\"(.*)\"$ ]] && echo "${BASH_REMATCH[1]}" || echo "uid2-operator-config-key")
  CORE_BASE_URL=$([[ "$(echo "${USER_DATA}" | grep CORE_BASE_URL=)" =~ ^export\ CORE_BASE_URL=\"(.*)\"$ ]] && echo "${BASH_REMATCH[1]}" || echo "")
  OPTOUT_BASE_URL=$([[ "$(echo "${USER_DATA}" | grep OPTOUT_BASE_URL=)" =~ ^export\ OPTOUT_BASE_URL=\"(.*)\"$ ]] && echo "${BASH_REMATCH[1]}" || echo "")
  ENFORCE_HTTPS=$([[ "$(echo "${USER_DATA}" | grep ENFORCE_HTTPS=)" =~ ^export\ ENFORCE_HTTPS=\"(.*)\"$ ]] && echo "${BASH_REMATCH[1]}" || echo "false")
else
  echo "Unrecognized IDENTITY_SCOPE ${IDENTITY_SCOPE}"
  exit 1
fi
echo "UID2_CONFIG_SECRET_KEY=${UID2_CONFIG_SECRET_KEY}"
echo "CORE_BASE_URL=${CORE_BASE_URL}"
echo "OPTOUT_BASE_URL=${OPTOUT_BASE_URL}"
echo "ENFORCE_HTTPS=${ENFORCE_HTTPS}"

export AWS_REGION_NAME=$(curl -s -x socks5h://127.0.0.1:3305 http://169.254.169.254/latest/dynamic/instance-identity/document/ | jq -r ".region")
echo "AWS_REGION_NAME=${AWS_REGION_NAME}"
echo "127.0.0.1 secretsmanager.${AWS_REGION_NAME}.amazonaws.com" >> /etc/hosts

IAM_ROLE=$(curl -s -x socks5h://127.0.0.1:3305 http://169.254.169.254/latest/meta-data/iam/security-credentials/)
echo "IAM_ROLE=${IAM_ROLE}"

CREDS_ENDPOINT="http://169.254.169.254/latest/meta-data/iam/security-credentials/${IAM_ROLE}"
export AWS_ACCESS_KEY_ID=$(curl -s -x socks5h://127.0.0.1:3305 "${CREDS_ENDPOINT}" | jq -r ".AccessKeyId")
export AWS_SECRET_KEY=$(curl -s -x socks5h://127.0.0.1:3305 "${CREDS_ENDPOINT}" | jq -r ".SecretAccessKey")
export AWS_SESSION_TOKEN=$(curl -s -x socks5h://127.0.0.1:3305 "${CREDS_ENDPOINT}" | jq -r ".Token")

# -- load configs via proxy
echo "Loading config overrides..."
export OVERRIDES_CONFIG="/app/conf/config-overrides.json"
python3 /app/load_config.py > "${OVERRIDES_CONFIG}"

export DEPLOYMENT_ENVIRONMENT=$(jq -r ".environment" < "${OVERRIDES_CONFIG}")
echo "DEPLOYMENT_ENVIRONMENT=${DEPLOYMENT_ENVIRONMENT}"
if [ -z "${DEPLOYMENT_ENVIRONMENT}" ]; then
  echo "DEPLOYMENT_ENVIRONMENT cannot be empty"
  exit 1
fi
if [ "${DEPLOYMENT_ENVIRONMENT}" != "prod" ] && [ "${DEPLOYMENT_ENVIRONMENT}" != "integ" ]; then
  echo "Unrecognized DEPLOYMENT_ENVIRONMENT ${DEPLOYMENT_ENVIRONMENT}"
  exit 1
fi

echo "Loading config final..."
export FINAL_CONFIG="/app/conf/config-final.json"
if [ "${IDENTITY_SCOPE}" = "UID2" ]; then
  python3 /app/make_config.py /app/conf/prod-uid2-config.json /app/conf/integ-uid2-config.json ${OVERRIDES_CONFIG} "$(nproc)" > ${FINAL_CONFIG}
elif [ "${IDENTITY_SCOPE}" = "EUID" ]; then
  python3 /app/make_config.py /app/conf/prod-euid-config.json /app/conf/integ-euid-config.json ${OVERRIDES_CONFIG} "$(nproc)" > ${FINAL_CONFIG}
else
  echo "Unrecognized IDENTITY_SCOPE ${IDENTITY_SCOPE}"
  exit 1
fi

get_config_value() {
  jq -r ".\"$1\"" ${FINAL_CONFIG}
}

# for number/boolean
# https://jqlang.github.io/jq/manual/
# --argjson foo 123 will bind $foo to 123.
TMP_FINAL_CONFIG="/tmp/final-config.tmp"
function jq_inplace_update_json() {
    local file=$1
    local field=$2
    local value=$3
    jq --argjson v "${value}" ".${field} = \$v" "${file}" > "${TMP_FINAL_CONFIG}" && mv "${TMP_FINAL_CONFIG}" "${file}"
}

# -- replace base URLs if both CORE_BASE_URL and OPTOUT_BASE_URL are provided
# -- using hardcoded domains is fine because they should not be changed frequently
if [ -n "${CORE_BASE_URL}" ] && [ -n "${OPTOUT_BASE_URL}" ] && [ "${DEPLOYMENT_ENVIRONMENT}" != "prod" ]; then
    echo "Replacing core and optout URLs by ${CORE_BASE_URL} and ${OPTOUT_BASE_URL}..."
    sed -i "s#https://core-integ.uidapi.com#${CORE_BASE_URL}#g" "${FINAL_CONFIG}"
    sed -i "s#https://core-prod.uidapi.com#${CORE_BASE_URL}#g" "${FINAL_CONFIG}"
    sed -i "s#https://optout-integ.uidapi.com#${OPTOUT_BASE_URL}#g" "${FINAL_CONFIG}"
    sed -i "s#https://optout-prod.uidapi.com#${OPTOUT_BASE_URL}#g" "${FINAL_CONFIG}"
fi

# -- replace `enforce_https` value to ENFORCE_HTTPS if provided
if [ "${ENFORCE_HTTPS}" == false ] && [ "${DEPLOYMENT_ENVIRONMENT}" != "prod" ]; then
    echo "Replacing enforce_https by ${ENFORCE_HTTPS}..."
    jq_inplace_update_json "${FINAL_CONFIG}" enforce_https false
fi

cat "${FINAL_CONFIG}"

# -- setup loki
echo "Setting up Loki..."
[[ "$(get_config_value 'loki_enabled')" == "true" ]] \
  && SETUP_LOKI_LINE="-Dvertx.logger-delegate-factory-class-name=io.vertx.core.logging.SLF4JLogDelegateFactory -Dlogback.configurationFile=./conf/logback.loki.xml" \
  || SETUP_LOKI_LINE=""

HOSTNAME=$(curl -s -x socks5h://127.0.0.1:3305 http://169.254.169.254/latest/meta-data/local-hostname)
echo "HOSTNAME=${HOSTNAME}"

# -- set pwd to /app so we can find default configs
cd /app

# -- start operator
echo "Starting Java application..."
java \
  -XX:MaxRAMPercentage=95 -XX:-UseCompressedOops -XX:+PrintFlagsFinal \
  -Djava.security.egd=file:/dev/./urandom \
  -Djava.library.path=/app/lib \
  -Dvertx-config-path="${FINAL_CONFIG}" \
  $SETUP_LOKI_LINE \
  -Dhttp_proxy=socks5://127.0.0.1:3305 \
  -jar /app/"${JAR_NAME}"-"${JAR_VERSION}".jar
