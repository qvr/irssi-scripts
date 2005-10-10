#!/bin/sh
# GoogleCalc.sh for irssi/whatever v1
# (c) Matti Hiljanen <matti@hiljanen.com>

# say 
#   /alias gcalc exec - <path to googlecalc.sh> "$0-" 
# in irssi and you should be all set :)

if [ $# -eq 0 ]
then
	echo "GoogleCalc.sh:"
	echo "  Usage: /gcalc <expression>"
    echo "      For examples see http://www.google.com/help/calculator.html"
	exit 0
fi 
echo "GoogleCalc.sh:"
expr="$1"

file="/tmp/.gcalc.tmp.${RANDOM}${RANDOM}"
lynx -dump "http://www.google.com/search?q=${expr}=" > $file 

temp=`cat $file|grep -i -e "More about calculator." > /dev/null`
if [ $? -ne 1 ]
  then
    result=`cat $file|grep "\[calc_img.gif\]"|sed -e 's/\[calc_img.gif\]//g'`
    echo "$result"
  else
    # Google didn't recognise the expression, and parsed it as a normal search query
	echo "4  Syntax error."
fi
rm $file
