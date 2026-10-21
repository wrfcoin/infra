#!/bin/bash
# DDoS Protection Script for Wrfcoin

# Iptables rules for DDoS protection
iptables -A INPUT -p tcp --dport 80 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT

# Protect against SYN flood attacks
iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
iptables -A INPUT -p tcp --syn -j DROP

# Protect against ping of death
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT

# Block excessive connections from single IP
iptables -A INPUT -p tcp --dport 80 -m connlimit --connlimit-above 20 -j REJECT
iptables -A INPUT -p tcp --dport 443 -m connlimit --connlimit-above 20 -j REJECT

# Log suspicious activity
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables denied: " --log-level 7

echo "DDoS protection rules applied"
