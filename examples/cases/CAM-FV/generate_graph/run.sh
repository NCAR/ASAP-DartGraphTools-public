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

# System variables:
MPIRUN='mpiexec_mpt'

cd $PBS_O_WORKDIR
${MPIRUN} -n 1 ${GRAPH_GENERATE_EXE} > generate_log.txt
