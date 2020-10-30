#!/bin/sh
# reconfigures libvirt network's DNS config and host's so "wildcard DNS" works for the OCP cluster domain
# assumes to be run by root user on a host that runs and hosts OCP cluster(s) on its KVM/libvirt
# $1=libvirt network for the cluster; eg. test-9xnsr
# $2=cluster domain; eg. test.redhat.com
# $3=gateway address into the cluster; eg. bastion node's address, 192.168.126.1

CNETWK=$1
if [ -z "$CNETWK" ]; then
    echo "ERROR: no libvirt cluster network specified -- aborting..."
    exit 1
fi

CDOMAIN=$2
if [ -z "$CDOMAIN" ]; then
    echo "ERROR: no server domain name specified -- aborting..."
    exit 2
fi

TOPADDR=$3
if [ -z "$TOPADDR" ]; then
    echo "ERROR: no cluster address specified -- aborting..."
    exit 3
fi

virsh net-info $CNETWK > /dev/null
if [ $? -ne 0 ]; then
    echo "ERROR: invalid cluster network specified -- aborting..."
    exit 4
fi

virsh net-dumpxml $CNETWK | grep -q "localOnly='yes'"
if [ $? -eq 0 ]; then
    # ------------------------------------------------------------
    echo "INFO: editing cluster network config..."
    #
    SEDF=`mktemp`
    echo "s/localOnly='yes'/localOnly='no'/" > $SEDF
    EDITOR="sed -i -f $SEDF" virsh net-edit $CNETWK
    if [ $? -ne 0 ]; then
        echo "ERROR: virsh net-edit failed -- aborting..."
        exit 5
    fi
    rm -f $SEDF

    # ------------------------------------------------------------
    echo "INFO: stopping cluster network..."
    #
    virsh net-destroy $CNETWK
    if [ $? -ne 0 ]; then
        echo "ERROR: virsh net-destroy failed -- aborting..."
        exit 6
    fi

    # ------------------------------------------------------------
    echo "INFO: starting cluster network..."
    #
    virsh net-start $CNETWK
    if [ $? -ne 0 ]; then
        echo "ERROR: virsh net-start failed -- aborting..."
        exit 7
    fi

    sleep $WAIT

    # ------------------------------------------------------------
    echo "INFO: restarting libvirtd..."
    #
    systemctl restart libvirtd
    [ $? -ne 0 ] && echo "WARNING: libvirtd may have failed to restart..."
else
    echo "INFO: cluster DNS already configured to work with upstream"
fi

DNSMASQD=/etc/NetworkManager/dnsmasq.d
grep -q /$CDOMAIN/ $DNSMASQD/*
if [ $? -ne 0 ]; then
    # ------------------------------------------------------------
    echo "INFO: adding new rule to host dnsmasq..."
    #
    echo "server=/$CDOMAIN/$TOPADDR\naddress/.$CDOMAIN/$TOPADDR" > $DNSMASQD/$CNETWK.conf

    # ------------------------------------------------------------
    echo "INFO: restarting NetworkManager..."
    #
    systemctl restart NetworkManager
    [ $? -ne 0 ] && echo "WARNING: NetworkManager may have failed to restart..."

    sleep $WAIT
else
    echo "INFO: host dnsmasq already configured for: $CDOMAIN"
fi

echo ""
echo "INFO: All completed successfully! It might take a minute or two before new DNS rules kick in..."
echo ""

echo "INFO: testing a lookup for bogus.$CDOMAIN..."
nslookup -timeout=60 bogus.$CDOMAIN