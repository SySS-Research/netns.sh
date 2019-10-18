`netns.sh` is a simple script that makes using network namespaces easier.
Network namespaces allow for different network configurations for different
processes. This makes it possible to restrict certain programs to one network
and prevent them from accessing another network.

`netns.sh` handles the task of assigning (physical) network interfaces to
network namespaces, bringing the interfaces up and running command in
namespaces.
More complex setups, e.g. involving virtual ethernet interfaces, routing
between namespaces or bridges are beyond the scope of this script.

Requirements
============

* Linux >= 2.6.24
* bash >= 4
* coreutils
* grep
* sudo
* iproute2
* a DHCP client, such as (optional, for DHCP support)
    * dhclient (package `net-misc/dhcp` on Gentoo, `isc-dhcp-client` on Debian,
      `extra/dhclient` on Arch)
    * udhcpc (package `sys-app/busybox` on Gentoo, `busybox` on Debian,
      `community/busybox` on Arch)
    * dhcpcd (package `net-misc/dhcpcd` on Gentoo, `dhcpcd5` on Debian,
      `core/dhcpcd` on Arch)
* iw >= 4.9 (optional, for wireless interface support)
* procps, inotify-tools (optional, for automatically repairing DNS information
  when broken by NetworkManager or similar)

Installation
============

No installation is required.
It may be desirable to make this script available in `$PATH`, possibly by using
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
symlink resides (i.e. possibly not in `$PATH`).

For example to change the name of the default namespace, the following could be
added to `netns.conf`.
```sh
# Name of the default network namespace that is used when no name is given.
default_netns="green"
```

The full list of available configuration options can be found in the first few
lines of `netns.sh` itself.

dhclient
--------

By default, `netns.sh` uses `dhclient` to configure the network inside the
network namespace. (See [Network Configuration](#network-configuration) below
for details).

Unfortunately, `dhclient` on most Linux distributions (with the notable
exception of Gentoo) fails to set up `/etc/resolv.conf` within a network
namespace. It usually produces an error message such as
```
mv: cannot move '/etc/resolv.conf.dhclient-new' to '/etc/resolv.conf': Device or resource busy
```

The file `dhclient-enter-hooks` provided within this repository can be used to
solve this. It should be placed in `/etc/dhcp/` or `/etc/` (distribution
specific). Or, possibly, somewhere else. The correct location can be found in
the source code of `/sbin/dhclient-script`.

Once the file is moved/copied/linked/... there, and sudo is configured to
preserve the `$NETNS` environment variable (see [below](#sudo)), `dhclient`
should just work™.
However, the hook overrides the default function that creates
`/etc/resolv.conf`. The function within the hook may not be appropriate for all
environments due to varying distribution specific modifications. Thus,
system-specific adjustment may be necessary on a case-by-case basis.
Note that there is always the option of using another DHCP client.

The provided hook will only trigger when `dhclient` is run by `netns.sh` (or
within an environment that sufficiently mimics `netns.sh`) in order to avoid
issues with other system components.

NetworkManager
--------------

If NetworkManager is used to manage the network connections in the main
namespace, this may, unfortunately, affect network namespaces as well.
In particular, connecting/disconnecting/reconnecting in the main namespace can
break the namespace-specific `/etc/resolv.conf` for processes that already run
in a network namespace. Processes started using `netns.sh run ...` afterwards
are not affected, processes started from an already running shell (or
something) keep their parent's broken DNS configuration.

The core issue is that NetworkManager deletes and recreates `/etc/resolv.conf`
instead of simply updating it's contents. This breaks bind mounts of that file
which are set up by `ip netns exec`.

There are three known workarounds for this situation, none of which is
particularly clean.

### Restart Everything

As mentioned above, it suffices to stop all running processes in network
namespaces and bring everything up again using `netns.sh run ...` after each
network change in the global scope.

### Repair Everything

Another approach is to restore the namespace-specific `/etc/resolve.conf`
whenever it breaks. The file `netns-repaird.sh` contains a simple daemon that
watches for issues and fixes them automatically.
In the default configuration, `netns.sh` starts this daemon in the background,
but it can also be used manually.

It is to note that this daemon does not only work on network namespaces managed
by `netns.sh`, but attempts fixing *all* network namespaces on the system.

The downside of this approach is that it only fixes `/etc/resolv.conf` *after*
it breaks, but does not prevent it from breaking in the first place.
Thus, there is always a (somewhat small) time window during which the processes
in the network namespace have an incorrect DNS configuration.

### Prevent NetworkManager from Breaking Everything

NetworkManager can be configured so that it does not break DNS settings in
network namespaces.
This is achieved by first configuring NetworkManager to not touch
`/etc/resolv.conf`. Second, a dispatcher script needs to be added that updates
`/etc/resolv.conf` from the version NetworkManager maintains internally.

Add the following to `/etc/NetworkManager/NetworkManager.conf`:
```conf
[main]
rc-manager=unmanaged
```

Add a file called `/etc/NetworkManager/dispatcher.d/00-rc-manager.sh` (or
similar) with the following content (or similar) and make it executable:
```sh
#!/bin/sh
# This script is called whenever a connection is started, stopped, etc.
# Unconditionally sync NetworkManager's resolv.conf into the system file.
cat /run/NetworkManager/resolv.conf > /etc/resolv.conf
```

Since `/etc/resolv.conf` is never deleted, the namespace-specific files are not
affected. Thus, operation within the network namespace can continue
uninterrupted.

However, as this configuration affects everything that NetworkManager does, one
should carefully consider the security implications.

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
Defaults env_keep += "NETNS"
```

Note: It may be advisable to restrict this setting to the `netns.sh` script by
modifying the above line appropriately (c.f. `sudoers(5)`).

shell
-----

As mentioned earlier, `netns.sh` exports the name of the namespace in use in
the environment variable `$NETNS`. It may be desirable to include that
information in the shell prompt or some other suitable location for easy
reference.

Zsh users may want to put the supplied file `_netns` in a directory referenced
by `$fpath`. This files provides a command line completion function for
`netns.sh`.

Usage
=====

An overview of the supported actions and parameters may be obtained by running
```sh
netns.sh --help
```

Firstly, it is to note that running `netns.sh` requires root privileges for
all operations. Obtaining them via sudo or pkexec is recommended as this allows
dropping privileges to the invoking user without further configuration.

Setup
-----

When using network namespaces, the first thing to do is create a namespace and
set it up appropriately. `netns.sh` automates this process as far as possible.
Running the following command creates a new namespace with the default name and
moves the network interface `eth0` into the namespace.
```sh
netns.sh start eth0
```
Multiple network interfaces can be moved into the namespace:
```sh
netns.sh start eth0 eth1 eth2
```
Interfaces can be added and removed after the namespace was created:
```sh
netns.sh add eth3
netns.sh remove eth0
```

To create a namespace with a different name (e.g. `green`) use something like
the following:
```sh
netns.sh start -n green eth0
```
`netns.sh` is capable of managing multiple namespaces and uses the name to
identify them. All commands that should not operate on the default namespace
require the target namespace's name.

Once a network interface is moved to a namespace, it is no longer available
outside of the namespace.
`netns.sh` tries to configure the network interfaces inside the namespace using
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
netns.sh run -n green ip addr
```
The command can be omitted. In this case, an interactive shell is started.
```sh
netns.sh run
```

Before running the given command inside the namespace, `netns.sh` attempts to
drop privileges. The parameter `--user` may be used to select the
user account the command should run as.
If it is not given, the default user from the configuration file is used.
If no user was set in the configuration file, the user invoking `sudo` or
`pkexec` is used instead. Failing that as well, `netns.sh` falls back to the
user from the environment variable `$USER`.

Cleanup
-------

Network namespaces are not persistent across reboots. However, it may not
always be convenient to reboot the system in order to free the respective
network interfaces.
As mentioned in section [Setup](#setup) above, interfaces can be removed from
an existing namespace.
Furthermore, it is possible to destroy and clean up a namespace, freeing all
interfaces at once. To delete the default namespace:
```sh
netns.sh stop
```
As usual, a name can/must be given to remove a namespace other than the default
one. No usage example is provided here.

When the `stop` command is invoked, the network interfaces within the namespace
are brought down and then removed from the namespace.
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
script. `netns.sh` comes with three simple scripts capable of bringing up the
interface using `dhclient`, `udhcpc` or `dhcpcd`, respectively.
There is also a script that runs `dnsmasq` to provide DHCP and DNS via the
given interface.

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
