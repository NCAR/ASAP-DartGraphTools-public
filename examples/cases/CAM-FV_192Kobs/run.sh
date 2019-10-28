#!/bin/bash
#PBS -N example1
#PBS -A NTDD0004
#PBS -l walltime=1:00:00
#PBS -q regular
#PBS -j oe
#PBS -l select=1:ncpus=36:mpiprocs=1

# Step 1 : Set up the variables to various executables:

ROOT=../../../
GRAPH_GENERATE_EXE=${ROOT}/generation/DART.graph_generation/models/cam-fv/work/filter.graph_generation
ADJ2G=${ROOT}/conversion/adj2g/adj2g.exe
G2MTX=${ROOT}/conversion/g2mtx/g2mtx.exe
COLPACK=${ROOT}/coloring/ColPack/Examples/ColPackAll/ColPack

# System variables:

MPIRUN='mpiexec_mpt'

# Add in some checking that we have them all before running [todo]


# Step 2 : Run the (serial, and thus slow) graph generation

cd $PBS_O_WORKDIR
${MPIRUN} -n 1 ${GRAPH_GENERATE_EXE} > generate_log.txt

${ADJ2G} < obdata2.txt > obgraph.g

${G2MTX} < obgraph.g > obgraph.mtx

${COLPACK} -f ./obgraph.mtx -o LARGEST_FIRST -m DISTANCE_ONE  > colors.txt



