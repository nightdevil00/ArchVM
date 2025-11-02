#!/bin/bash
rfkill unblock wifi
iwctl station wlan0 connect TP-Link_A168_5G --passphrase 02234984
