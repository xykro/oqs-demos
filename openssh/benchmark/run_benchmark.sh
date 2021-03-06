#!/bin/bash

DIR=${0%/*}

PORT=${PORT:=2222}
CONTAINER=${CONTAINER:="oqs-client"}
OQS_USER=${OQS_USER:="oqs"}
DOCKER_OPTS=${DOCKER_OPTS:=""}
TSHARK_INTERFACE=${TSHARK_INTERFACE:="any"}
TSHARK_STARTDELAY=${TSHARK_STARTDELAY:=2}

if [ $# -lt 1 ]; then
    echo "Provide the server's IP address!"
    echo "Aborting..."
    exit 1
else
    SERVER=$1
fi

DEBUGLVL=${DEBUGLVL:=0}

echo "### Configuration ###"
echo "Server IP: ${SERVER}"
echo "Port:      ${PORT}"
echo "Debug LVL: ${DEBUGLVL}"

function evaldbg {
    if [ $DEBUGLVL -ge 2 ]; then
        echo "Debug: Executing '$@'"
    fi
    eval $@
    return $?
}

# read listoftests.conf
SIGS=()
KEMS=()
NUM_LOOPS=()
while read -r KEM SIG NUM_LOOP; do 
    [[ ${KEM} == "" ]] || [[ ${KEM} =~ ^#.* ]] && continue # Check if first character is '#'
    KEMS+=("${KEM}")
    SIGS+=("${SIG}")
    NUM_LOOPS+=("${NUM_LOOP}")
    # echo "i found >${SIGS[-1]}< >${KEMS[-1]}< >${NUM_LOOPS[-1]}<"
done < "$DIR/listoftests.conf"

# Add pre and postfixes to algorithm names if needed
# KEM: ecdh-nistp384-<KEM>-sha384@openquantumsafe.org if PQC algorithm, else <KEM>
[[ $DEBUGLVL -ge 1 ]] &&
    echo "" &&
    echo "### Renaming KEMs ###"
for i in ${!KEMS[@]}; do
    [[ $DEBUGLVL -ge 1 ]] &&
        echo -n "${KEMS[i]} --> "
    if [[ ${KEMS[i],,} != "curve25519-sha256"* ]] && [[ ${KEMS[i],,} != "ecdh-sha2-nistp"* ]] && [[ ${KEMS[i],,} != "diffie-hellman-group"* ]]; then
        # Add postfix
        if [[ ${KEMS[i],,} != *"-sha384@openquantumsafe.org" ]]; then
            KEMS_FULL[i]="${KEMS[i],,}-sha384@openquantumsafe.org"
        fi
    else
        KEMS_FULL[i]="${KEMS[i],,}"
    fi
    [[ $DEBUGLVL -ge 1 ]] &&
        echo "${KEMS_FULL[i]}"
done
# SIG: ssh-<SIG> if PQC algorithm, else <SIG>
[[ $DEBUGLVL -ge 1 ]] &&
    echo "" &&
    echo "### Renaming SIGs ###"
for i in ${!SIGS[@]}; do
    [[ $DEBUGLVL -ge 1 ]] &&
        echo -n "${SIGS[i]} --> "
    if [[ ${SIGS[i],,} == *"@openssh.com" ]]; then
        echo "[FAIL] Use an algorithm without the '@openssh.com' postfix, they are not supported at the moment."
        echo "Use one of the following: ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521"
        exit 1
    elif [[ ${SIGS[i],,} == *"rsa"* ]] && [[ ${SIGS[i],,} != *"rsa3072"* ]]; then
        echo "[FAIL] No support for any rsa algorithm."
        echo "Use one of the following: ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521"
        exit 1
    elif [[ ${SIGS[i],,} != "ecdsa-sha2-nistp"* ]] && [[ ${SIGS[i],,} != "ssh-ed25519" ]]; then
        # Add Prefix
        if [[ ${SIGS[i],,} != "ssh-"* ]]; then
            SIGS_FULL[i]="ssh-${SIGS[i],,}"
        fi
    else
        SIGS_FULL[i]="${SIGS[i],,}"
    fi
    [[ $DEBUGLVL -ge 1 ]] &&
        echo "${SIGS_FULL[i]}"
done

# Create directory for storing the results
evaldbg DATETIME=$(date +"%Y-%m-%d_%H-%M-%S")
RESULTSDIR="${DIR}/measurements/${DATETIME}"
if [[ ! -d ${RESULTSDIR} ]]; then
    mkdir ${RESULTSDIR}
fi

echo ""
echo "### Run tests ###"

# Get timestamp

# Build tshark filter (any interface, ssh and tcp, server address:port)
TSHARK_FILTER="\"tcp port ${PORT}\""

# Configure SSH options
SSH_GLOBAL_OPTS="-p ${PORT} -o BatchMode=yes -q"
if [[ $DEBUGLVL -ge 3 ]]; then
    SSH_GLOBAL_OPTS="${SSH_GLOBAL_OPTS} -v"
fi
SSH_DIR="/home/${OQS_USER}/.ssh"
# Loop over all tests
TEST_FAIL=0
for i in ${!SIGS_FULL[@]}; do
#   Start tshark capture for <SIG>_<KEM>
    evaldbg "tshark -i ${TSHARK_INTERFACE} -f ${TSHARK_FILTER} -w \"${RESULTSDIR}/${i}_${KEMS[i]}_${SIGS[i]}.pcap\" -q &"
    TSHARK_PID=$!
    sleep ${TSHARK_STARTDELAY}
#   Do test n times
    SSH_OPTS="${SSH_GLOBAL_OPTS} -i ${SSH_DIR}/id_${SIGS[i]//-/_} -o PubKeyAcceptedKeyTypes=${SIGS_FULL[i]//_/-} -o KexAlgorithms=${KEMS_FULL[i]//_/-}"
    for j in $(eval echo {1..${NUM_LOOPS[i]}}); do
        evaldbg docker exec --user ${OQS_USER} -i ${DOCKER_OPTS} ${CONTAINER} ssh ${SSH_OPTS} ${OQS_USER}@${SERVER} 'exit 0'
        if [[ $? -eq 0 ]]; then
            echo "${KEMS[i]^^} and ${SIGS[i]^^}           ${j}/${NUM_LOOPS[i]} runs done "
        else
            echo "[FAIL] in run ${j}/${NUM_LOOPS[i]}"
            TEST_FAIL=1
            if [[ ${SIGKEM_FAIL[@]} != *"${SIGS[i]^^} and ${KEMS[i]^^}"* ]]; then
                SIGKEM_FAIL+=("${SIGS[i]^^} and ${KEMS[i]^^}")
            fi
        fi
    done
    killall tshark
    echo ""
done

if [ $TEST_FAIL -eq 0 ]; then
    echo "### [ OK ] ### All tests done!"
else
    echo -n "### [FAIL] ### There were problems with: "
    for FAIL in ${SIGKEM_FAIL[@]}; do
        echo "${FAIL} "
    done
    echo "### [INFO] ### Skipping evaluation, run '${DIR}/eval_benchmark.sh' manually"
    exit 1
    echo ""
fi

evaldbg ${DIR}/eval_benchmark.sh ${RESULTSDIR}