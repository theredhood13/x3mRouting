#!/bin/sh
# VERSION=1.0.0
filedir=/etc/openvpn/dns
filebase="$(echo "$filedir"/"$dev" | sed 's/\(tun\|tap\)1/client/;s/\(tun\|tap\)2/server/')"
conffile="$filebase"\.conf
resolvfile="$filebase"\.resolv
dnsscript="$(echo /etc/openvpn/fw/"$(echo "$dev")"-dns\.sh | sed 's/\(tun\|tap\)1/client/;s/\(tun\|tap\)2/server/')"
qosscript="$(echo /etc/openvpn/fw/"$(echo "$dev")"-qos\.sh | sed 's/\(tun\|tap\)1/client/;s/\(tun\|tap\)2/server/')"
fileexists=
instance="$(echo "$dev" | sed 's/tun1//;s/tun2*/0/')"
serverips=
searchdomains=
# added for debugging
/usr/bin/logger -t "openvpn-updown-doug" "Value of filebase ==> $filebase"
/usr/bin/logger -t "openvpn-updown-doug" "Value of conffile ==> $conffile"
/usr/bin/logger -t "openvpn-updown-doug" "Value of dnsscript ==> $dnsscript"
/usr/bin/logger -t "openvpn-updown-doug" "Value of instance ==> $instance"
/usr/bin/logger -t "openvpn-updown-doug" "Value of script_type ==> $script_type"

create_client_list() {
  server="$1"
  VPN_IP_LIST="$(nvram get vpn_client"$(echo "$instance")"_clientlist)"
  # addedvfor debugging
  /usr/bin/logger -t "openvpn-updown-doug" "Value of VPN_IP_LIST Paramater at first setting is==> $VPN_IP_LIST"
  ## Xentrk: update updown.sh to use custom nvram files in /jffs/configs
  if [ -s "/jffs/configs/ovpnc${instance}.nvram" ]; then
    VPN_IP_LIST=${VPN_IP_LIST}$(cat "/jffs/configs/ovpnc${instance}.nvram")
    /usr/bin/logger -t "openvpn-updown-doug" "Value of VPN_IP_LIST Paramater at second setting is==> $VPN_IP_LIST"
  fi
  ###### end of modifications
  OLDIFS=$IFS
  IFS="<"

  for ENTRY in $VPN_IP_LIST; do
    if [ "$ENTRY" = "" ]; then
      continue
    fi

    VPN_IP="$(echo "$ENTRY" | cut -d ">" -f 2)"
    /usr/bin/logger -t "openvpn-updown-doug" "Value of VPN_IP Paramater at first is==> $VPN_IP"
    if [ "$VPN_IP" != "0.0.0.0" ]; then
      TARGET_ROUTE=$(echo $ENTRY | cut -d ">" -f 4)
      if [ "$TARGET_ROUTE" = "VPN" ]; then
        echo /usr/sbin/iptables -t nat -A DNSVPN$instance -s $VPN_IP -j DNAT --to-destination $server >>$dnsscript
        /usr/bin/logger -t "openvpn-updown" "Forcing $VPN_IP to use DNS server $server"
      else
        echo /usr/sbin/iptables -t nat -I DNSVPN$instance -s $VPN_IP -j RETURN >>$dnsscript
        /usr/bin/logger -t "openvpn-updown" "Excluding $VPN_IP from forced DNS routing"
      fi
    fi
  done
  IFS=$OLDIFS
}

if [ ! -d $filedir ]; then mkdir $filedir; fi
if [ -f $conffile ]; then rm $conffile; fileexists=1; fi
if [ -f $resolvfile ]; then rm "$resolvfile"; fileexists=1; fi

if [ "$script_type" = "up" ]; then
  echo "#!/bin/sh" >> "$dnsscript"
  echo /usr/sbin/iptables -t nat -N DNSVPN"$instance" >> "$dnsscript"

  if [ "$instance" != 0 ] && [ "$(nvram get vpn_client"$(echo "$instance")"_rgw)" -ge 2 ] && [ "$(nvram get vpn_client"$(echo $instance)"_adns)" = 3 ]; then
    setdns=0
  else
    setdns=-1
  fi

  # Extract IPs and search domains; write WINS
  	for optionname in `set | grep "^foreign_option_" | sed "s/^\(.*\)=.*$/\1/g"`
  	do
  		option=`eval "echo \\$$optionname"`
  		if echo $option | grep "dhcp-option WINS "; then echo $option | sed "s/ WINS /=44,/" >> $conffile; fi
  		if echo $option | grep "dhcp-option DNS"; then serverips="$serverips $(echo $option | sed "s/dhcp-option DNS //")"; fi
  		if echo $option | grep "dhcp-option DOMAIN"; then searchdomains="$searchdomains $(echo $option | sed "s/dhcp-option DOMAIN //")"; fi
  	done

# Write resolv file
    	for server in $serverips
    	do
    		echo "server=$server" >> $resolvfile
    		if [ $setdns == 0 ]
    		then
    			create_client_list $server
    			setdns=1
    		fi
    		for domain in $searchdomains
    		do
    			echo "server=/$domain/$server" >> $resolvfile
    		done
    	done

    	if [ "$setdns" = 1 ]
    	then
    		echo /usr/sbin/iptables -t nat -I PREROUTING -p udp -m udp --dport 53 -j DNSVPN$instance >> $dnsscript
    		echo /usr/sbin/iptables -t nat -I PREROUTING -p tcp -m tcp --dport 53 -j DNSVPN$instance >> $dnsscript
    	fi


      # QoS
      	if [ $instance != 0 -a $(nvram get vpn_client$(echo $instance)_rgw) -ge 1 -a $(nvram get qos_enable) -eq 1 -a $(nvram get qos_type) -eq 1 ]
      	then
      		echo "#!/bin/sh" >> $qosscript
      		echo /usr/sbin/iptables -t mangle -A POSTROUTING -o br0 -m mark --mark 0x40000000/0xc0000000 -j MARK --set-xmark 0x80000000/0xC0000000 >> $qosscript
      		/bin/sh $qosscript
      	fi
      fi


if [ "$script_type" = "down" ] && [ $instance != 0 ]; then
  /usr/sbin/iptables -t nat -D PREROUTING -p udp -m udp --dport 53 -j DNSVPN$instance
  /usr/sbin/iptables -t nat -D PREROUTING -p tcp -m tcp --dport 53 -j DNSVPN$instance
  /usr/sbin/iptables -t nat -F DNSVPN$instance
  /usr/sbin/iptables -t nat -X DNSVPN$instance

  if [ -f "$qosscript" ]
	then
		sed -i "s/-A/-D/g" "$qosscript"
		/bin/sh "$qosscript"
		rm "$qosscript"
  fi
fi

if [ -f "$conffile" ] || [ -f "$resolvfile" ] || [ -n "$fileexists" ]; then
  if [ "$script_type" = "up" ]; then
    if [ -f "$dnsscript" ]; then
      /bin/sh "$dnsscript"
    fi
    /sbin/service updateresolv
  elif [ "$script_type" = "down" ]; then
    # added for debugging
    /usr/bin/logger -t "openvpn-updown-doug" "Value of script type ==> $script_type"
    rm -rf "$dnsscript"
    /sbin/service updateresolv # also restarts or reloads dnsmasq as necessary
    #		/sbin/service restart_dnsmasq
    # RMerl committed on Jan 11
    if [ "$(nvram get vpn_client"$(echo "$instance")"_adns)" = 2 ]
      then
        /sbin/service restart_dnsmasq
      else
        /sbin/service updateresolv
    fi
    # End RMerl committed on Jan 11
  fi
fi

rmdir "$filedir"
rmdir /etc/openvpn

if [ -f /jffs/scripts/openvpn-event ]; then
  /usr/bin/logger -t "custom_script" "Running /jffs/scripts/openvpn-event (args: $*)"
  /bin/sh /jffs/scripts/openvpn-event "$*"
fi

exit 0
