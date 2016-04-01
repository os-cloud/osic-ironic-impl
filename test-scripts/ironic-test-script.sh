#!/bin/bash
#
# deploy_node - helper script to deploy using IPMI/PXE and ironic-python-agent
#
# Change these settings to match your environment
# IRONIC TEST SCRIPT
# Written by: "michael.davies@RACKSPACE.COM" <michael.davies@RACKSPACE.COM>

export NAME="xxxxxx"                 # what you want to refer to your node as
export MAC="xx:xx:xx:xx:xx:xx"       # PXE bootable MAC on the node
export HTTPADDRESS="xxx.xxx.xxx.xxx" # ironic-api node IP addr
export IPMIADDRESS="xxx.xxx.xxx.xxx" # your node's drac/ilo IP addr
export IPMIUSER="xxxx"
export IPMIPASSWORD="xxxxxn"         # Remember to escape $ and \

export DEPLOYRAMDISK="http://${HTTPADDRESS}/images/deploy/coreos_production_pxe_image-oem.cpio.gz"
export DEPLOYKERNEL="http://${HTTPADDRESS}/images/deploy/coreos_production_pxe.vmlinuz"

export USERIMAGE="http://${HTTPADDRESS}/images/user/my-image.qcow2"
export USERIMAGEMD5="a52a1cb7efe8ee336f7e9b1a5ecb5a46"

# Should we watch the provisioning state changes?
WATCH=1

export IRONIC='ironic'
export IPMITOOL='ipmitool'
export WATCH_CMD='watch'

__check_cmd_avail ()
{
    if [ z$(which $1) == "z" ]; then
        echo "The command '$1' could not be found, exiting"
        exit 1
    fi
}

# Verify we havew the commands we need
__check_cmd_avail ${IPMITOOL}
__check_cmd_avail ${IRONIC}
__check_cmd_avail ${WATCH_CMD}

# Load the openstack credentials
[[ -f "${OPENRC:-/root/openrc}" ]] && source /root/openrc

# Unenroll and delete the node if it's there
${IRONIC} node-set-maintenance ${NAME} on
${IRONIC} node-delete ${NAME}

# Turn off the node and start from power down
${IPMITOOL} -I lanplus -H ${IPMIADDRESS} -L ADMINISTRATOR -U ${IPMIUSER} -R 12 -N 5 -P ${IPMIPASSWORD} power off

# Enroll the node
${IRONIC} node-create -d agent_${IPMITOOL} -i ipmi_address="${IPMIADDRESS}" -i ipmi_password="${IPMIPASSWORD}" -i ipmi_username="${IPMIUSER}" -i deploy_ramdisk="${DEPLOYRAMDISK}" -i deploy_kernel="${DEPLOYKERNEL}" -n ${NAME}

${IRONIC} node-update ${NAME} add instance_info/image_source="${USERIMAGE}" instance_info/root_gb=20 instance_info/image_checksum="${USERIMAGEMD5}"

NODEUUID=$(${IRONIC} node-list | grep ${NAME} | cut -f 2 -d "|" )

${IRONIC} port-create -n ${NODEUUID} -a ${MAC}

${IRONIC} node-validate ${NAME}

# Start the deploy
${IRONIC} node-set-provision-state ${NAME} active

# Watch what's going on
if [[ ${WATCH} -eq 1 ]]; then
    ${WATCH_CMD} ${IRONIC} node-show ${NAME}
fi