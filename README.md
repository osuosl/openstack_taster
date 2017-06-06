# openstack_taster
Tests a complete OpenStack deployment for various functionalities

# Usage

1. Make the following variables available through your shell:

* **OS_USERNAME** -- Username to authenticate to the OpenStack API
* **OS_PASSWORD** -- plain text password for the user account
* **OS_TENANT_NAME** admin -- the "project" or tenant under which the test
  instances will be created. Make sure you have permissions and resources to
  create m1.small instances and one single free public ip.
* **OS_AUTH_URL** -- URL where OpenStack API lives. something like https://openpower-openstack.testing.osuosl.org:5000/v2.0
* **OS_REGION_NAME** -- The region where the instances should be created.
* **OS_PRIVATE_SSH_KEY** -- Path to the private key of the pair to access these created
  instances using ssh.
* **OS_PUBLIC_SSH_KEY** -- Path to the public key of the keypair which will be put
  in the instances once they are created
* **OS_SSH_KEYPAIR** -- Name under which the public key is *already* saved in the
  OpenStack Key Pairs.

  All variables are mandatory.

2. Once they are set, make sure to install all the depedencies.

   ``` console
   $ gem build openstack_taster.gemspec
   $ gem install openstack_taster*.gem
   ```
3. Run, from the root of this repo, ``ruby -Ilib bin/openstack_taster``.
This will create, test, and destroy instances using all the images and volumes available to the user and log everything inside logs/${FQDN of Openstack controller you are testing on}. Each run will create a directory named after the session id and inside that you will find a log file for each image that you are testing.
