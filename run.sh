#!/bin/bash
apt-get update && apt-get install -y wget
wget https://github.com/doktor83/SRBMiner-Multi/releases/download/3.3.3/SRBMiner-Multi-3-3-3-Linux.tar.gz
tar -xvf SRBMiner-Multi-3-3-3-Linux.tar.gz
./SRBMiner-Multi-3-3-3/SRBMiner-MULTI --algorithm pearlhash --pool pearl-sg1.luckypool.io:3360 --wallet prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 --worker rtx5090
