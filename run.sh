#!/usr/bin/env bash


cluster=$1
if [[ -z $cluster ]]; then
  cluster=slp
fi

solana_version=0.23.2

case $cluster in
slp)
  rpc_url=http://34.82.79.31
  ;;
tds)
  rpc_url=http://tds.solana.com
  ;;
*)
  echo "Error: unsupported cluster: $cluster"
  exit 1
  ;;
esac

set -e
cd "$(dirname "$0")"

. configure-metrics.sh

if [[ -n $CI ]]; then
  curl -sSf https://raw.githubusercontent.com/solana-labs/solana/v$solana_version/install/solana-install-init.sh \
    | sh -s - $solana_version \
        --no-modify-path \
        --data-dir ./solana \
        --config config.yml

  export PATH="$PWD/solana/releases/$solana_version/solana-release/bin/:$PATH"
fi

current_slot=$(solana --url $rpc_url get-slot)
validators=$(solana --url $rpc_url show-validators)

max_slot_distance=216000 # ~24 hours worth of slots at 2.5 slots per second

# Current validators:
for id_slot in $(echo "$validators" | sed -ne "s/^  \([^ ]*\)   *[^ ]* *[0-9]*%  *\([0-9]*\) .*/\1=\2/p"); do
  declare id=${id_slot%%=*}
  declare slot=${id_slot##*=}
  $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=true slot=${slot}"
done

# Delinquent validators:
for id_slot in $(echo "$validators" | sed -ne "s/^\(⚠️ \|! \)\([^ ]*\)   *[^ ]* *[0-9]*%  *\([0-9]*\) .*/\2=\3/p"); do
  declare id=${id_slot%%=*}
  declare slot=${id_slot##*=}
  if ((slot < current_slot - max_slot_distance)); then
    $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=false slot=${slot}"
  else
    $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=true slot=${slot}"
  fi
done

exit 0
