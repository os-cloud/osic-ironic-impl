Basic host setup
----------------

Store this repository locally

.. code-block:: bash

    git clone https://github.com/os-cloud/osic-ironic-impl /opt/osic-ironic-impl


Create a temporary ansible deployment venv

.. code-block:: bash

    cd /opt/osic-ironic-impl
    pip install virtualenv
    virtualenv ansible-temp
    source ansible-temp/bin/activate
    ansible-temp/bin/pip install ansible


With the temporary virtual environment activated, distribute keys

.. code-block:: bash

    ssh-keygen
    SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
    ansible os-control -i inventory-static-hosts.ini -m shell -a "echo ${SSH_KEY} | tee -a /root/.ssh/authorized_keys" --ask-pass


With the temporary virtual environment activated, make sure all hosts have bridge-utils, ifenslave, and vlan installed

.. code-block:: bash

    ansible os-control -i inventory-static-hosts.ini -m shell -a 'apt-get update && apt-get install bridge-utils ifenslave vlan -y'


With the temporary virtual environment activated, deploy the base network configuration file

.. code-block:: bash

    ansible deploy -i inventory-static-hosts.ini -m template -a 'src=templates/base-interfaces.cfg.j2 dest=/etc/network/interfaces'


With the temporary virtual environment activated, deploy all of the network interface files for the cloud

.. code-block:: bash

    ansible os-control -i inventory-static-hosts.ini -m template -a 'src=templates/os-refimpl-devices.cfg.j2 dest=/etc/network/interfaces.d/os-refimpl-devices.cfg'


With the temporary virtual environment activated, deploy the VIP addresses to your Loadbalancer host

.. code-block:: bash

    ansible deploy -i inventory-static-hosts.ini -m template -a 'src=templates/os-refimpl-floats.cfg.j2 dest=/etc/network/interfaces.d/os-refimpl-floats.cfg'


With the temporary virtual environment activated, ensure extra interface files are parsed

.. code-block:: bash

    ansible os-control -i inventory-static-hosts.ini -m shell -a "if ! grep '^source /etc/network/interfaces.d/*.cfg'; then echo '\nsource /etc/network/interfaces.d/*.cfg' | tee -a /etc/network/interfaces; fi"


With the temporary virtual environment activated, bring all of the extra interfaces online

.. code-block:: bash

    ansible os-control -i inventory-static-hosts.ini -m shell -a "for i in \$(awk '/iface/ {print \$2}' /etc/network/interfaces.d/os-refimpl-devices.cfg); do ifup \$i; done"


With all that complete deactivate the venv

.. code-block:: bash

    deactivate


OpenStack Ansible Deployment
----------------------------

Gather the openstack-ansible source code.

.. code-block:: bash

    git clone https://github.com/openstack/openstack-ansible /opt/openstack-ansible


Move to the cloned directory and execute the ansible bootstrap command

.. code-block:: bash

    cd /opt/openstack-ansible
    ./scripts/bootstrap-ansible.sh


Create the local openstack_deploy configuration directory

.. code-block:: bash

    cp -R etc/openstack_deploy /etc/openstack_deploy
    # OPTIONAL: Run some aio, example, and sample file cleanup.
    rm /etc/openstack_deploy/*.{aio,example,sample} || true
    rm /etc/openstack_deploy/conf.d/*.{aio,example,sample} || true
    rm /etc/openstack_deploy/env.d/*.{aio,example,sample} || true


Copy  all of the OSA config in place

.. code-block:: bash

    cd /opt/osic-ironic-impl
    cp osa-config-files/conf.d/* /etc/openstack_deploy/conf.d/
    cp osa-config-files/openstack_user_config.yml /etc/openstack_deploy/
    cp osa-config-files/user_variables.yml /etc/openstack_deploy/


Generate our user secrets

.. code-block:: bash

    cd /opt/openstack-ansible
    ./scripts/pw-token-gen.py --file /etc/openstack_deploy/user_secrets.yml


Modify the environment files force nova-compute to run from within a container.

.. code-block:: bash

    sed -i '/is_metal.*/d' /etc/openstack_deploy/env.d/nova.yml


Run the deployment

.. code-block:: bash

    cd /opt/openstack-ansible/playbooks
    openstack-ansible setup-everything.yml


Setup a neutron network for use Ironic
--------------------------------------

In the general case, the neutron network can be a simple flat network.
In the complex case, this can be whatever you need and want just make sure you adjust the deployment accordingly.


.. code-block:: bash

    neutron net-create ironic-net --shared \
                                    --provider:network_type flat \
                                    --provider:physical_network tftp

    neutron subnet-create ironic-net 172.19.0.0/22 --name ironic-subnet \
                                                   --ip-version=4 \
                                                   --allocation-pool start=172.19.1.100,end=172.19.1.200 \
                                                   --enable-dhcp \
                                                   --dns-nameservers list=true 8.8.4.4 8.8.8.8


Building Ironic Images
----------------------

Building images using the diskimage builder tools needs to be done outside of a container.
This for this process use one of the physical hosts within the environment. If you have a
cinder node, I'd recommend using it because OpenStack client access will have already been
setup.

Install some needed packages

.. code-block:: bash

    apt-get install -y qemu uuid-runtime curl


Install the disk-imagebuilder client

.. code-block:: bash

    pip install diskimage-builder --isolated


Force the ubuntu image-create process to use a modern kernel. **THIS IS REQUIRED FOR THE OSIC ENVIRONMENT**.
The OSIC host machines have an advanced driver need due to networking hardware that requires a very modern
kernel. For this reason the LTS kernel package install is absolutely required.

.. code-block:: bash

    echo 'linux-image-generic-lts-xenial:' > /usr/local/share/diskimage-builder/elements/ubuntu/package-installs.yaml


Create Ubuntu ramdisk

.. code-block:: bash

    disk-image-create ironic-agent ubuntu -o ironic-deploy


Upload the created deploy images into glance

.. code-block:: bash

    # Upload the deploy image kernel
    glance image-create --name ironic-deploy.kernel --visibility public --disk-format aki --container-format aki < ironic-deploy.kernel

    # Upload the user image initramfs
    glance image-create --name ironic-deploy.initramfs --visibility public --disk-format ari --container-format ari < ironic-deploy.initramfs


Create Ubuntu user image

.. code-block:: bash

    disk-image-create ubuntu baremetal dhcp-all-interfaces grub2 -o ubuntu-user-image


Upload the created user images into glance

.. code-block:: bash

    # Upload the user image vmlinuz and store uuid
    VMLINUZ_UUID="$(glance image-create --name ubuntu-user-image.vmlinuz --visibility public --disk-format aki --container-format aki  < ubuntu-user-image.vmlinuz | awk '/\| id/ {print $4}')"

    # Upload the user image initrd and store uuid
    INITRD_UUID="$(glance image-create --name ubuntu-user-image.initrd --visibility public --disk-format ari --container-format ari  < ubuntu-user-image.initrd | awk '/\| id/ {print $4}')"

    # Create image
    glance image-create --name ubuntu-user-image --visibility public --disk-format qcow2 --container-format bare --property kernel_id=${VMLINUZ_UUID} --property ramdisk_id=${INITRD_UUID} < ubuntu-user-image.qcow2


Creating an Ionic flavor
------------------------


Create ironic baremetal flavor type

.. code-block:: bash

    nova flavor-create osic-baremetal-flavor 5150 254802 78 48
    nova flavor-key osic-baremetal-flavor set cpu_arch=x86_64
    nova flavor-key osic-baremetal-flavor set capabilities:boot_option="local"


Enroll Ironic nodes
-------------------

Run the node enroll playbook

.. code-block:: bash

    cd /opt/osic-ironic-impl
    openstack-ansible -i /opt/osic-ironic-impl/inventory-static-hosts.ini ironic-node-enroll.yml -e "ilo_password=$ILO_PASSWORD"


Deploy a baremetal node kicked with ironic
------------------------------------------

Before deployment make sure you have a key set within nova. This is important, otherwise you will not have access.
If you do not have an ssh key already available that you wish to use, set one up with ``ssh-keygen``.

.. code-block:: bash

    nova keypair-add --pub-key ~/.ssh/id_rsa.pub admin


Now boot a node

.. code-block:: bash

    nova boot --flavor 5150 --image ubuntu-user-image --key-name admin ${NODE_NAME}


Ironic verification (optional)
------------------------------

Once the deployment is complete run a simple ironic test to verify everything is working

Copy a simple test script in place

.. code-block:: bash

    ansible utility_all -m copy -a 'src=ironic-test-script.sh dest=/opt/ironic-test-script.sh'


Login to the utility container and execute the test script. Note, you will need to edit the file to fill in your deployment details at the top of the script.

.. code-block:: bash

    bash -v /opt/ironic-test-script.sh


Notes
#####

* The nodes should be on their own PXE / TFTP server network. This network needs to be able to speak back to the OpenStack APIs. Specifically needs to are: Access to the Ironic API for the python ironic agent, and Swift for temporary URLs.
