#!/bin/bash
set -euo pipefail

REMOTE_HOST=$1
REMOTE_PORT=${REMOTE_PORT:-22}
CLUSTER_DIR=${CLUSTER_DIR:-cluster}
IDENT=${IDENT:-${HOME}/.ssh/id_rsa}

BOOTKUBE_REPO=quay.io/coreos/bootkube
BOOTKUBE_VERSION=v0.1.4

function usage() {
    echo "USAGE:"
    echo "$0: <remote-host>"
    exit 1
}

function configure_etcd() {
    [ -f "/etc/systemd/system/etcd2.service.d/10-etcd2.conf" ] || {
        mkdir -p /etc/systemd/system/etcd2.service.d
        cat << EOF > /etc/systemd/system/etcd2.service.d/10-etcd2.conf
[Service]
Environment="ETCD_NAME=controller"
Environment="ETCD_INITIAL_CLUSTER=controller=http://${COREOS_PRIVATE_IPV4}:2380"
Environment="ETCD_INITIAL_ADVERTISE_PEER_URLS=http://${COREOS_PRIVATE_IPV4}:2380"
Environment="ETCD_ADVERTISE_CLIENT_URLS=http://${COREOS_PRIVATE_IPV4}:2379"
Environment="ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379"
Environment="ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380"
EOF
    }
}

function configure_flannel() {
    # Configure Flannel options
    [ -f "/etc/flannel/options.env" ] || {
        mkdir -p /etc/flannel
        echo "FLANNELD_IFACE=${COREOS_PRIVATE_IPV4}" >> /etc/flannel/options.env
        echo "FLANNELD_ETCD_ENDPOINTS=http://127.0.0.1:2379" >> /etc/flannel/options.env
    }

    # Make sure options are re-used on reboot
    local TEMPLATE=/etc/systemd/system/flanneld.service.d/10-symlink.conf.conf
    [ -f $TEMPLATE ] || {
        mkdir -p $(dirname $TEMPLATE)
        echo "[Service]" >> $TEMPLATE
        echo "ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env" >> $TEMPLATE
    }
}

# wait until etcd is available, then configure the flannel pod-network settings.
function configure_network() {
    while true; do
        echo "Waiting for etcd..."
        /usr/bin/etcdctl cluster-health && break
        sleep 1
    done
    /usr/bin/etcdctl set /coreos.com/network/config '{ "Network": "10.2.0.0/16", "Backend":{"Type":"vxlan"}}'
}

# Initialize a Master node
function init_master_node() {
    systemctl daemon-reload
    systemctl stop update-engine; systemctl mask update-engine

    # Start etcd and configure network settings
    configure_etcd
    configure_flannel
    systemctl enable etcd2; sudo systemctl start etcd2
    configure_network

    # Start flannel
    systemctl enable flanneld; sudo systemctl start flanneld

    # Render cluster assets
    /home/core/bootkube render --asset-dir=assets --api-servers=https://${COREOS_PUBLIC_IPV4}:886,https://${COREOS_PRIVATE_IPV4}:443

    # Move the local kubeconfig into expected location
    chown -R core:core /home/core/assets
    mkdir -p /etc/kubernetes
    cp /home/core/assets/auth/kubeconfig /etc/kubernetes/

    # Start the kubelet
    systemctl enable kubelet; sudo systemctl start kubelet

    # Start bootkube to launch a self-hosted cluster
    /home/core/bootkube start --asset-dir=assets
}

[ "$#" == 1 ] || usage

[ -d "${CLUSTER_DIR}" ] && {
    echo "Error: CLUSTER_DIR=${CLUSTER_DIR} already exists"
    exit 1
}

# This script can execute on a remote host by copying itself + kubelet service unit to remote host.
# After assets are available on the remote host, the script will execute itself in "local" mode.
if [ "${REMOTE_HOST}" != "local" ]; then
    # Set up the kubelet.service on remote host
    scp -i ${IDENT} -P ${REMOTE_PORT} kubelet.master core@${REMOTE_HOST}:/home/core/kubelet.master
    ssh -i ${IDENT} -p ${REMOTE_PORT} core@${REMOTE_HOST} "sudo mv /home/core/kubelet.master /etc/systemd/system/kubelet.service"

    # Copy self to remote host so script can be executed in "local" mode
    scp -i ${IDENT} -P ${REMOTE_PORT} bootkube core@${REMOTE_HOST}:/home/core/bootkube
    scp -i ${IDENT} -P ${REMOTE_PORT} ${BASH_SOURCE[0]} core@${REMOTE_HOST}:/home/core/init-master.sh
    ssh -i ${IDENT} -p ${REMOTE_PORT} core@${REMOTE_HOST} "sudo /home/core/init-master.sh local"

    # Copy assets from remote host to a local directory. These can be used to launch additional nodes & contain TLS assets
    mkdir ${CLUSTER_DIR}
    scp -q -i ${IDENT} -P ${REMOTE_PORT} -r core@${REMOTE_HOST}:/home/core/assets/* ${CLUSTER_DIR}

    # Cleanup
    ssh -i ${IDENT} -p ${REMOTE_PORT} core@${REMOTE_HOST} "rm -rf /home/core/assets && rm -rf /home/core/init-master.sh"

    echo "Cluster assets copied to ${CLUSTER_DIR}"
    echo
    echo "Bootstrap complete. Access your kubernetes cluster using:"
    echo "kubectl --kubeconfig=${CLUSTER_DIR}/auth/kubeconfig get nodes"
    echo
    echo "Additional nodes can be added to the cluster using:"
    echo "./init-worker.sh <node-ip> ${CLUSTER_DIR}/auth/kubeconfig"
    echo

# Execute this script locally on the machine, assumes a kubelet.service file has already been placed on host.
elif [ "$1" == "local" ]; then
    init_master_node
fi
