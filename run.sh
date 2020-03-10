#!/usr/bin/env bash


cluster=$1
if [[ -z $cluster ]]; then
  cluster=slp
fi

solana_version=1.0.5

case $cluster in
devnet)
  rpc_url=http://devnet.solana.com:8899
  ;;
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

if [[ -n $STAKE_KEYPAIR ]]; then
  echo "$STAKE_KEYPAIR" > ${cluster}_stake_keypair.json
  staking_keypair=${cluster}_stake_keypair.json
fi

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


current_vote_pubkeys=()
delinquent_vote_pubkeys=()

# Current validators:
for id_vote_slot in $(echo "$validators" | sed -ne "s/^  \\([^ ]*\\)   *\\([^ ]*\\) *[0-9]*%  *\\([0-9]*\\) .*/\\1=\\2=\\3/p"); do
  declare id=${id_vote_slot%%=*}
  declare vote_slot=${id_vote_slot#*=}
  declare vote=${vote_slot%%=*}
  declare slot=${vote_slot##*=}

  current_vote_pubkeys+=("$vote")
  $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=true slot=${slot}"
done

# Delinquent validators:
for id_vote_slot in $(echo "$validators" | sed -ne "s/^\\(⚠️ \\|! \\)\\([^ ]*\\) *\\([^ ]*\\) *[0-9]*%  *\\([0-9]*\\) .*/\\2=\\3=\\4/p"); do
  declare id=${id_vote_slot%%=*}
  declare vote_slot=${id_vote_slot#*=}
  declare vote=${vote_slot%%=*}
  declare slot=${vote_slot##*=}

  if ((slot < current_slot - max_slot_distance)); then
    delinquent_vote_pubkeys+=("$vote")
    $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=false slot=${slot}"
  else
    current_vote_pubkeys+=("$vote")
    $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=true slot=${slot}"
  fi
done



#
# Run through all the current/delinquent vote accounts and delegate/deactivate
# stake.  This is done quite naively
#
[[ -n $staking_keypair ]] || exit
(
  set -x
  solana --keypair $staking_keypair balance
)
current=1
for vote_pubkey in "${current_vote_pubkeys[@]}" - "${delinquent_vote_pubkeys[@]}"; do
  if [[ $vote_pubkey = - ]]; then
    current=0
    continue
  fi

  seed="${vote_pubkey:0:32}"

  stake_address="$(solana --keypair $staking_keypair create-address-with-seed "$seed" STAKE)"
  echo "Vote account: $vote_pubkey | Stake address: $stake_address"
  if ! solana stake-account "$stake_address"; then
    (
      set -x
      solana --keypair $staking_keypair create-stake-account $staking_keypair --seed "$seed" 5000
    )
  fi

  if ((current)); then
    (
      set -x
      solana --keypair $staking_keypair delegate-stake "$stake_address" "$vote_pubkey"
    )
  else
    (
      set -x
      solana --keypair $staking_keypair deactivate-stake "$stake_address"
    )
  fi
done

exit 0
