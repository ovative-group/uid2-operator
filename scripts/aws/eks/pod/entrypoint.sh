#!/bin/bash -eufx
CID=16
EIF_PATH=/home/uid2operator.eif
MEMORY_MB=24576
CPU_COUNT=6

function terminate_old_enclave() {
    ENCLAVE_ID=$(nitro-cli describe-enclaves | jq -r ".[0].EnclaveID")
    [ "$ENCLAVE_ID" != "null" ] && nitro-cli terminate-enclave --enclave-id ${ENCLAVE_ID}
}

function setup_vsockproxy() {
    VSOCK_PROXY=${VSOCK_PROXY:-/home/vsockpx}
    VSOCK_CONFIG=${VSOCK_CONFIG:-/home/proxies.host.yaml}
    VSOCK_THREADS=${VSOCK_THREADS:-$(( $(nproc) * 2 )) }
    VSOCK_LOG_LEVEL=${VSOCK_LOG_LEVEL:-3}
    echo "starting vsock proxy at $VSOCK_PROXY with $VSOCK_THREADS worker threads..."
    $VSOCK_PROXY -c $VSOCK_CONFIG --workers $VSOCK_THREADS --log-level $VSOCK_LOG_LEVEL --daemon
    echo "vsock proxy now running in background."
}

function setup_dante() {
    ulimit -n 1024
    /home/sockd -D
}

function run_enclave() {
    echo "starting enclave..."
    nitro-cli run-enclave --cpu-count $CPU_COUNT --memory $MEMORY_MB --eif-path $EIF_PATH --enclave-cid $CID --enclave-name simple-eif --debug-mode --attach-console
}

terminate_old_enclave
setup_vsockproxy
setup_dante
run_enclave