# balena-pxe-boot

Effortlessly provision your new devices with balenaOS unattended over the network using the PXE protocol.

## Deploying

As simple as `balena push [my-fleet-name]`

## Configuration

The netboot server reads appId and apiKey pairs, delimited by colons, from the `FLEET_CONFIG` environment variable. Each pair is separated by a semicolon. This variable is required.

For example:
```
FLEET_CONFIG=[appId]:[apiKey];[appId]:[apiKey]
```

Only one appId per device type must be specified. If more than one fleet is being provisioned with the same device type, you'll need to switch your netboot server over from one fleet to the other, or setup multiple netboot servers on independent networks.

Upon startup, the netboot server application will download a configured image for the fleet you've specified, extract the kernel from it, and build an initramfs to install the image. The original kernel from the balenaOS release matching your device is used to ensure the required drivers are present.

The netboot server runs dnsmasq in DHCP proxy mode, which only responds to BOOTP requests, and does not hand out addresses. Consequently, it's safe to run this on an existing network with a DHCP server.

By default, the installation script will perform a dry run and exit, to avoid destroying data. Once you're certain no machines on your network will boot the installer unintentionally, set the environment variable `DRY_RUN=false` on the dashboard, or using the CLI, for the netboot server. This will instruct the server to perform the installation for real, which **will destroy the data on any machine that runs it.**

Even with `DRY_RUN=false`, the installer will not write to a disk with an existing partition table by default. If you want to override this behavior, specify `CLOBBER=true` as an environment variable for the netboot server.

## Usage

After the netboot server is configured and `DRY_RUN` is disabled, new devices can be provisioned simply by plugging them in and waiting for the installer to complete.
