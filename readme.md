`netns.sh` is a simple script that makes using network namespaces easier.
Network namespaces allow for different network configurations for different
processes. This makes it possible to restrict certain programs to one network
and prevent them from accessing another network.

Requirements
============

* Linux >= 2.6.24
* bash
* coreutils
* grep
* sudo
* iproute2
* dhclient (optional, package `net-misc/dhcp` on Gentoo,
   `isc-dhcp-client` on Debian, `extra/dhclient` on Arch)

Installation
============

No installation is required.
It may be desirable to make this script available in `$PATH`, possible by using
a symlink.
It may further be desirable to make a few changes to the system configuration,
as described below.

Configuration
=============

netns.conf
----------
A file named `netns.conf` placed in the same directory as the file `netns.sh`
can be used to change the default settings. When using a symlink (e.g. in
`$PATH`), the config file must be in the directory where the target of the
symlink resides (i.e. possible not in `$PATH`).

sudo
----

`netns.sh` exports the environment variable `$NETNS` to commands that run
inside the namespace. `$NETNS` contains the name of the namespace.
For this to work, sudo needs to be configured to allow passing this environment
variable to the invoked command.
This may be the default setting. If it is not, `netns.sh` will work fine
regardless. The environment variable is considered a convenience feature only.
However, since it really is useful, it may be desirable to configure sudo to
allow the export.
This can be achieved by adding the following line to one of the sudoers files:

```
Defaults! env_keep += "NETNS"
```

Note: It may be advisable to restrict this setting to the `netns.sh` script by
modifying the above line appropriately (c.f. `sudoers(5)`).

shell
-----

As mentioned earlier, `netns.sh` exports the name of the namespace in use in
the environment variable `$NETNS`. It may be desirable to include that
information in the shell prompt or some other suitable location for easy
reference.

Usage
=====

An overview of the supported actions and parameters may be obtained by running
```sh
netns.sh --help
```

Firstly, it is to note that running `netns.sh` requires root privileges for
all operations. Obtaining the via sudo is recommended as this allows dropping
privileges to the invoking user without further configuration.

Setup
-----

When using network namespaces, the first thing to do is create a namespace and
set it up appropriately. `netns.sh` automates this process as far as possible.
Running the following command creates a new namespace with the default name and
move the network interface `eth0` into the namespace.
```sh
netns.sh start eth0
```
To create a namespace with a different name (e.g. `green`) use something like
the following:
```sh
netns.sh start green eth0
```
`netns.sh` is capable of managing multiple namespaces and uses the name to
identify them. All commands that should not operate on the default namespace
require the target namespace's name.

Once the namespace is created, the network interface is no longer available
outside of the namespace.
`netns.sh` tries to configure the network interface inside the namespace using
DHCP. The network configuration can be customised using the parameter
`--script` (or `-s`) or using the config file.
Refer to section [Network Configuration](#network-configuration) below for
details.

Running Commands
----------------

The `run` command, surprisingly, allows running commands inside a namespace.
For instance, to view the network configuration in the default namespace, type:
```sh
netns.sh run ip addr
```
To view the network configuration in the `green` namespace:
```sh
netns.sh run green ip addr
```
The command can be omitted. In this case, an interactive shell is started.
```sh
netns.sh run
```
Note that the first parameter to `run` is interpreted as a namespace name if a
namespace with that name currently exists. If no such namespace exists, it is
interpreted as a command to run.
If this causes issues for you, you should rethink how you name your namespaces.

Before running the given command inside the namespace, `netns.sh` attempts to
drop privileges. The parameter `--user` may be used to select the
user account the command should run as.
If it is not given, the default user from the configuration file is used.
If no user was set in the configuration file, the user invoking `sudo` is used
instead. Failing that as well, `netns.sh` falls back to the user from the
environment variable `$USER`.

Cleanup
-------

Network namespaces are not persistent across reboots. However, it may not
always be convenient to reboot the system in order to free the respective
network interface.
Fortunately, `netns.sh` provides an easy way to destroy and clean up a
namespace. To delete the default namespace:
```sh
netns.sh stop
```
As usual, a name can/must be given to remove a namespace other than the default
one. No usage example is provided here.

When the `stop` command is invoked, the network interface within the namespace
is brought down and then removed from the namespace.
Finally, the namespace is deleted and the namespace-specific `resolv.conf` file
is deleted.
Note that this file remains if the system is shut down without invoking the
`stop` command. One should consider the implications of having DNS information
(which may be considered sensitive) remaining in that file.
Note further that the names of namespaces that were used persist on the
filesystem even if `netns.sh` is used to remove the namespaces. They may be
manually removed from `/etc/netns/` if desired.

Network Configuration
---------------------

Configuring the network interface within the network namespace is done via a
script. `netns.sh` comes with a simple script capable of bringing up the
interface using `dhclient`.

For other means of configuring the network, a new script should be written.
The script receives two parameters. The first is the action to perform and is
either `up` or `down`. The second parameter is the name of the network
interface that is to be configured.
The script should terminate with exit code 0 if the network was successfully
configured and with some other exit code if there was an error.

The script runs inside the namespace and may do whatever is appropriate for
configuring the network, such as setting static IP addresses, invoking another
DHCP client or connecting to a WiFi.
It is to note, however, that a system wide daemon (such as NetworkManager) can
_not_ be used here. Since the daemon runs in the global scope, it does not have
access to the interface to be configured.
A daemon with network namespace support, on the other hand, may be usable.
