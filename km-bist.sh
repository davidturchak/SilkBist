#!/bin/bash
#title          :loopback iface creation
#description    :This script can create an iface and to connect it to target
#author         :David Turchak
#date           :17/8/2021
#version        :1.0
#============================================================================



# stop on any error
#set -e

LOOPBACK='loopback'
SSH_PWD='cluster_pwd'
PMC_IP=$(ifconfig ib0 | grep 'inet addr' | tr ':' ' ' | awk '{print $3 }')
SSH_CONN_STR="sshpass -p $SSH_PWD ssh -o StrictHostKeyChecking=no"
LOCAL_DP_IP1=$(ifconfig eth6 | grep 'inet addr' | tr ':' ' ' | awk '{print $3 }')
LOCAL_DP_IP2=$(ifconfig eth7 | grep 'inet addr' | tr ':' ' ' | awk '{print $3 }')
MLOCAL_DP_IP1=${LOCAL_DP_IP1}*
MLOCAL_DP_IP2=${LOCAL_DP_IP2}*
KCLI='/opt/km/cli/km-cli'
NUM_ISCSI_SESSIONS=8
iqn_suff=$(hostname)                                
initiator_name_file="/etc/iscsi/initiatorname.iscsi"
iqn_str=$(head -n 1 $initiator_name_file)           
fe_iqn="${iqn_str/InitiatorName=/}"                 
if_iqn_prefix=${fe_iqn%f*}                          




function usage(){

            echo "Illegal number of parameters \n Parameters:"
            echo "Usage: $0 -c {ifcreate | ifremove | sdpcreate | sdpremove | distribute}"
            echo "Example: $0 -c sdpcreate"
            exit 1
}



if [ "$#" -lt 1 ]; then
	usage
fi

while getopts n:t:c: option
do
        case "${option}"
        in
                n) NUM_ISCSI_SESSIONS=${OPTARG};;
                p) SSH_PWD=${OPTARG};;
		c) CMD=${OPTARG};;
        esac
done


function create_ifaces
{
	iscsiadm -m iface -I $LOOPBACK -o new &> /dev/null
	iscsiadm -m iface -I $LOOPBACK -o update -n iface.initiatorname -v ${if_iqn_prefix}${iqn_suff} &> /dev/null
}

function remove_ifaces
{
  	iscsiadm -m iface -I $LOOPBACK -o delete &> /dev/null
}

function disconnect_iface
{
      iscsiadm -m node -I $LOOPBACK -u &> /dev/null
      find /var/lib/iscsi/nodes/ -type d -name k2 -exec rm -rf {} +
}

function connect_tgt
{

     TIQN1=$(iscsiadm -m discovery -I $LOOPBACK -o new -t st -p $LOCAL_DP_IP1 -P 1 | grep Target | awk '{print $2}')
     iscsiadm -m node -T $TIQN1 -o update -n node.session.nr_sessions -v $NUM_ISCSI_SESSIONS
     find /var/lib/iscsi/nodes/iqn.*  -type d | grep $LOCAL_DP_IP1 | grep k2 | grep 3260 | xargs rm -rf
     iscsiadm -m node -I $LOOPBACK -l &> /dev/null

}

function create_hosts
{
echo "Creating hosts objects on SDP"
$KCLI -c "volume host-group-create name=${LOOPBACK}_HG" &> /dev/null

for cnode in ${cnodes}; do
 $KCLI -c "volume host-create name=${cnode} os_type=Linux connectivity_type=iSCSI host_group=${LOOPBACK}_HG" &> /dev/null
 $KCLI -c "volume host-change name=${cnode} iqn_add=${if_iqn_prefix}${cnode}" &> /dev/null
done
}


function creare_and_map_vol
{
echo "Creating and mapping test volume for loopback initiators"
$KCLI -c "volume volume-group-create name=${LOOPBACK}_vg dedup=false quota=unlimited" &> /dev/null
$KCLI -c "volume volume-create group=${LOOPBACK}_vg name=${LOOPBACK}_vol size=200GB enable_vmware_support=false dedup=false" &> /dev/null
$KCLI -c "volume mapping-create volumes=${LOOPBACK}_vol host_group=${LOOPBACK}_HG" &> /dev/null
}

function unmap_and_del_vol
{
echo "Cleaning up SDP objects"
$KCLI -c "volume mapping-remove volumes=loopback_vol host_group=${LOOPBACK}_HG silent=true" &> /dev/null
for cnode in ${cnodes}; do
 $KCLI -c "volume host-remove name=$cnode silent=true" &> /dev/null
done
$KCLI -c "volume host-group-remove silent=true name=${LOOPBACK}_HG" &> /dev/null
$KCLI -c "volume volume-remove name=${LOOPBACK}_vol silent=true" &> /dev/null
$KCLI -c "volume volume-group-remove silent=true name=${LOOPBACK}_vg" &> /dev/null
}


function distribute
{
for cnode_ip in ${cnodes_ips}; do
 if [ $cnode_ip != $PMC_IP ]; then
 	echo "Cloning $0 and fio to $cnode_ip"
 	$SSH_CONN_STR -n -f $cnode_ip "sh -c '/usr/bin/pkill -x fio'"
 	sshpass -p cluster_pwd scp -o StrictHostKeyChecking=no $0 fio $cnode_ip:/root/
 fi
done

}

function ssh_execute
{
 $SSH_CONN_STR $1 /root/$0 -c $2
}

function get_num_of_cnodes
{
cnodes=$(/opt/km/cli/km-cli -c "system server-show" | grep c- | cut -f1 -d '|')
cnodes_ips=$(/opt/km/cli/km-cli -c "system server-show" | grep c- | cut -f10 -d '|' | cut -f1 -d ',')
}


function create_fio_input
{

if [ $1 == $PMC_IP ] ; then 
cat  << xxEOFxx > tiling_$PMC_IP
[global]
size=100%
bs=256K
direct=1
ioengine=libaio
group_reporting
iodepth=16
numjobs=1
name=tiling_job
rw=write
buffer_compress_percentage=66
refill_buffers
buffer_pattern=0xdeadbeef
[job1]
xxEOFxx

echo "filename=$(sg_map -x -i | grep KMNRIO | grep -v '0 0 0  0' | awk '{print $7}' | head -n 1)" >> tiling_$PMC_IP

fi
 
cat  << xxEOFxx > iops_read_fio_$1
[global]    
bs=4K
direct=1
ioengine=libaio
group_reporting
time_based
runtime=9999
iodepth=24
numjobs=8
name=iops_read_job
rw=randread
[job1]
xxEOFxx

cat  << xxEOFxx > iops_write_fio_$1
[global]
bs=4K
direct=1
ioengine=libaio
group_reporting
time_based
runtime=9999
iodepth=20
numjobs=8
name=iops_read_job
rw=randwrite
buffer_compress_percentage=66
refill_buffers
buffer_pattern=0xdeadbeef
[job1]
xxEOFxx
    
cat  << xxEOFxx > bw_read_fio_$1
[global]
bs=128K
direct=1
ioengine=libaio
group_reporting
time_based
runtime=9999
iodepth=24
numjobs=1
name=bw_read_job
rw=randread
[job1]
xxEOFxx

cat  << xxEOFxx > bw_write_fio_$1  
[global]
bs=128K
direct=1
ioengine=libaio
group_reporting
time_based
runtime=9999
iodepth=20
numjobs=1
name=bw_write_job
rw=randwrite
buffer_compress_percentage=66
refill_buffers
buffer_pattern=0xdeadbeef
[job1]
xxEOFxx

for i in $($SSH_CONN_STR $1 "sg_map -x -i | grep KMNRIO | grep -v '0 0 0  0' | awk '{print \$7}'"); do 
echo filename=$i | tee -a *_fio_$1 > /dev/null 2>&1
done

}


#Parsing acction 
case ${CMD} in
        ifcreate)
		if pgrep -f mastat >/dev/null; then
			get_num_of_cnodes
			for cnode_ip in ${cnodes_ips}; do
				echo "Executing creation on $cnode_ip"
				ssh_execute $cnode_ip "localifcreate"
			done
		fi
            	;;
        localifcreate)
		disconnect_iface
		remove_ifaces
		create_ifaces
		connect_tgt
            	;;
        ifremove)
		if pgrep -f mastat >/dev/null; then
			get_num_of_cnodes
			for cnode_ip in ${cnodes_ips}; do
				echo "Executing deletion on $cnode_ip"
				ssh_execute $cnode_ip "localifremove"
				done
			fi
            	;;
	localifremove)
		disconnect_iface
		remove_ifaces
		pkill -x fio
            	;;
	sdpcreate)
		if pgrep -f mastat >/dev/null; then
			get_num_of_cnodes
			create_hosts
			creare_and_map_vol
		fi
            	;;
	sdpremove)
		if pgrep -f mastat >/dev/null; then
			get_num_of_cnodes
			unmap_and_del_vol
		fi
            	;;
	distribute)
		if pgrep -f mastat >/dev/null; then
			get_num_of_cnodes
			distribute
			fi
		;;
	iocreate)
		if pgrep -f mastat >/dev/null; then
			get_num_of_cnodes
			for cnode_ip in ${cnodes_ips}; do
				echo "Restarting FIO server on $cnode_ip"
				$SSH_CONN_STR -n -f $cnode_ip '/usr/bin/pkill -x screen'
				$SSH_CONN_STR $cnode_ip "screen -d -m /root/fio --server=$cnode_ip,17582"	
				$SSH_CONN_STR $cnode_ip "/usr/bin/pgrep -x fio > /dev/null && echo "--client=$cnode_ip,17582" || echo "fio process is not running!""
				echo "Creating input files for $cnode_ip"
			        create_fio_input $cnode_ip
			done
		fi
            	;;
        *)
            usage
esac
