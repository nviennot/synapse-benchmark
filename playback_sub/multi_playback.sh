#!/bin/bash

export DIR=$1
export NUM_WORKERS=`ls $DIR | wc -l`

for file in `ls $DIR`; do
  PLAYBACK_FILE="$DIR/$file" promiscuous -r app.rb subscribe &
done

wait
