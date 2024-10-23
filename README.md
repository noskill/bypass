# bypass
Various scripts for bypassing internet censorship. These scripts should work on any router that can supports entware.  

For installation on keenetic routers see

https://help.keenetic.com/hc/en-us/articles/360021888880-Installing-OPKG-Entware-in-the-router-s-internal-memory
https://help.keenetic.com/hc/ru/articles/360021888880-%D0%A3%D1%81%D1%82%D0%B0%D0%BD%D0%BE%D0%B2%D0%BA%D0%B0-OPKG-Entware-%D0%BD%D0%B0-%D0%B2%D1%81%D1%82%D1%80%D0%BE%D0%B5%D0%BD%D0%BD%D1%83%D1%8E-%D0%BF%D0%B0%D0%BC%D1%8F%D1%82%D1%8C-%D1%80%D0%BE%D1%83%D1%82%D0%B5%D1%80%D0%B0

additionally go to http://192.168.1.1/controlPanel/system/components

and install 

kenel modules for netfilter:

![image](https://github.com/user-attachments/assets/e337ae67-50ef-4183-8539-1367d6edbfe5)


## Overview

Basically we are creating rules to redirect matching tcp and udp traffic via remoute vps.


## router setup

login to router with ssh and install packages
```
# opkg install iptables vim"
```
see [https://github.com/noskill/bypass/master/packages.txt](https://github.com/noskill/bypass/blob/master/packages.txt) for complete list of packages

## vps setup


