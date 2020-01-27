#!/usr/bin/env bash
# this script is used to launch Harmony validatro nodes using terraform recipe

source ./regions.sh
ME=`basename $0`
SSH='ssh -o StrictHostKeyChecking=no -o LogLevel=error -o ConnectTimeout=5 -o GlobalKnownHostsFile=/dev/null'

set -o pipefail
# set -x

if [ "$(uname -s)" == "Darwin" ]; then
   TIMEOUT=gtimeout
else
   TIMEOUT=timeout
fi

if [[ -z "$WHOAMI" || "$WHOAMI" == "ec2-user" ]]; then
   echo WHOAMI is not set or set to ec2-user
   exit 0
fi

if [ -z "$HMY_PROFILE" ]; then
   echo HMY_PROFILE is not set
   exit 0
fi

function logging
{
   echo $(date) : $@
   SECONDS=0
}

function errexit
{
   logging "$@ . Exiting ..."
   exit -1
}

# expense has to be called after logging
function expense
{
   local step=$1
   local duration=$SECONDS
   logging $step took $(( $duration / 60 )) minutes and $(( $duration % 60 )) seconds
}

function verbose
{
   [ $VERBOSE ] && echo $@
}

STATEDIR=states

function usage
{
   cat<<EOF
Usage: $ME [Options] Command
This script will be used to manage AWS terraform nodes: launch new one, run rclone, wait for rclone finish

PREREQUISITE:
 * this script can only be run on devop.hmny.io host
 * make sure you have [mainnet] section in ~/.aws/credentials
 * set WHOAMI environment variable (export WHOAMI=???)
 * set HMY_PROFILE environment variable (export HMY_PROFILE=???)
 * terraform state file directory, using sync_state.sh to upload/download the terraform.tfstate files
 * log directory of all init*.json files, default to logs/\$HMY_PROFILE

OPTIONS:
   -h                         print this help message
   -n                         dry run mode
   -v                         verbose mode
   -G                         do the real job
   -s state-file-directory    specify the directory of the terraform state files (default: $STATEDIR)
   -d log-file-directory      specify the directory of the log directory (default: logs/$HMY_PROFILE)

COMMANDS:
   new [list of index]        list of index of the harmony node in internal/genesis/harmony.go, delimited by space
   rclone [list of ip]        list of IP addresses to do rlcone, delimited by space
   wait [list of ip]          list of IP addresses to wait until rclone finished, check every minute
   uptime [list of ip]        list of IP addresses to update uptime robot, will generate uptimerobot.sh cli

EXAMPLES:

   $ME -v

   $ME new 20 30 5

   $ME rclone 12.34.56.78 123.234.123.234

   $ME wait 12.34.56.78 123.234.123.234

EOF
   exit 0
}

# launch one terraform node based on index
function _do_launch_one {
   local index=$1

   if [ -z $index ]; then
      echo no index, exit
      return
   fi
   if [[ $index -le 0 || $index -ge 680 ]]; then
      echo index: $index is out of bound
      return
   fi

   region=${REGIONS[$RANDOM % ${#REGIONS[@]}]}
   terraform apply -var "aws_region=$region" -var "blskey_index=$index" -auto-approve || return
   sleep 3
   IP=$(terraform output -json | jq -rc '.public_ip.value  | @tsv')
   echo "$IP" >> $OUTPUT
   sleep 1
   mv -f terraform.tfstate states/terraform.tfstate.$index
}

function do_state_sync
{
   aws --profile mainnet s3 sync states/ s3://mainnet.log/states/
}

function new_instance
{
   indexes=$@
   rm -f ip.txt
   for i in $indexes; do
      _do_launch_one $i
      echo $IP >> ip.txt
   done

   do_state_sync
}

# use rclone to sync harmony db
function rclone_sync
{
   ips=$@
   for ip in $ips; do
      $SSH ec2-user@$ip 'nohup /home/ec2-user/rclone.sh > rclone.log 2> rclone.err < /dev/null &'
   done
}

function do_wait
{
   ips=$@
   declare -A DONE
   for ip in $ips; do
      DONE[$ip]=false
   done

   min=0
   while true; do
      for ip in $ips; do
         rc=$($SSH ec2-user@$ip 'pgrep -n rclone')
         if [ -n "$rc" ]; then
            echo "rclone is running on $ip. pid: $rc."
         else
            echo "rclone is not running on $ip."
         fi
         hmy=$($SSH ec2-user@$ip 'pgrep -n harmony')
         if [ -n "$hmy" ]; then
            echo "harmony is running on $ip. pid: $hmy"
            DONE[$ip]=true
         else
            echo "harmony is not running on $ip."
         fi
      done

      alldone=true
      for ip in $ips; do
         if ! ${DONE[$ip]}; then
            alldone=false
            break
         fi
      done

      if $alldone; then
         echo All Done!
         break
      fi
      echo "sleeping 60s, $min minutes passed"
      sleep 60
      (( min++ ))
   done

   for ip in $ips; do
      $SSH ec2-user@$ip 'tac latest/zerolog*.log | grep -m 1 BINGO'
   done
   date
}

function update_uptime
{
   ips=$@
   for ip in $ips; do
      idx=$($SSH ec2-user@$ip 'cat index.txt')
      shard=$(( $idx % 4 ))
      echo ./uptimerobot.sh -t t3 -i $idx update t3-$idx $ip $shard
      echo ./uptimerobot.sh -t t3 -i $idx -G update t3-$idx $ip $shard
   done
}

###############################################################################
LOGDIR=../../pipeline/logs/$HMY_PROFILE
DRYRUN=echo
OUTPUT=$LOGDIR/$(date +%F.%H:%M:%S).log

while getopts "hnvGss:d:" option; do
   case $option in
      n) DRYRUN=echo [DRYRUN] ;;
      v) VERBOSE=-v ;;
      G) DRYRUN= ;;
      s) STATEDIR=$OPTARG ;;
      d) LOGDIR=$OPTARG ;;
      h|?|*) usage ;;
   esac
done

shift $(($OPTIND-1))

CMD="$1"
shift

if [ -z "$CMD" ]; then
   usage
fi

if [ ! -d $STATEDIR ]; then
   echo invalid state directory: $STATEDIR
   exit 0
fi

if [ ! -d $LOGDIR ]; then
   echo invalid log directory: $LOGDIR
   exit 0
fi

case $CMD in
   new) new_instance $@ ;;
   rclone) rclone_sync $@ ;;
   wait) do_wait $@ ;;
   uptime) update_uptime $@ ;;
   *) usage ;;
esac
