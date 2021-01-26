#!/bin/sh
while true; do
    result=$(curl -m 5 -k -s -o /dev/null -I -w "%{http_code}" "https://bookinfo.tetrate.zwickey.net/productpage")
    echo date: $(date),  status code: "$result"
    #sleep .5
done
