#!/bin/bash
#PBS -N example
#PBS -A NTDD0004
#PBS -l walltime=1:00:00
#PBS -q regular
#PBS -j oe
#PBS -l select=1:ncpus=36:mpiprocs=36

# Set up the variables to various executables:
ROOT=../../../../
FILTER=${ROOT}/DART.original/models/cam-fv/work/filter
DATA=/glade/p/cisl/asap/data/GraphDART/CAM-FV/
MPIRUN='mpiexec_mpt'

# Link in the input files
cd $PBS_O_WORKDIR
ENS_SIZE=$(grep ens_size input.nml  | grep "=" | head -1 | awk '{print $3}')
for i in $(seq 1 ${ENS_SIZE}); do
  NUM=$(printf "%04d" ${i})
  ln -s ${DATA}/fv_testcase.i.${NUM}.nc .
done

ln -s ${DATA}/caminput.nc .
ln -s ${DATA}/cam_phis.nc .
ln -s ${DATA}/restart_files_in.txt .
ln -s ${DATA}/restart_files_out.txt .

ln -s ../../../inputs/observation_sequence_files/CAM-FV/obs_seq_192K_testfile.txt ./obs_seq.out

# Run filter:
${MPIRUN} ${FILTER} > dart_original_log.txt

