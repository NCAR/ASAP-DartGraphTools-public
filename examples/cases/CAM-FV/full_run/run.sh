#!/bin/bash
#PBS -N example1
#PBS -A NTDD0004
#PBS -l walltime=3:00:00
#PBS -q regular
#PBS -j oe
#PBS -l select=1:ncpus=36:mpiprocs=36:mem=109G

# Step 1 : Set up the variables to various executables:
ROOT=../../../../
GRAPH_GENERATE_EXE=${ROOT}/generation/DART.graph_generation/models/cam-fv/work/filter
GRAPH_RUN_EXE=${ROOT}/DART.graph/models/cam-fv/work/filter
ADJ2G=${ROOT}/conversion/adj2g/adj2g.exe
G2MTX=${ROOT}/conversion/g2mtx/g2mtx.exe
COLPACK=${ROOT}/coloring/ColPack/Examples/ColPackAll/ColPack
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


# Run

${MPIRUN} -n 1 ${GRAPH_GENERATE_EXE} > generate_log.txt

${ADJ2G} < obdata2.txt > obgraph.g

${G2MTX} < obgraph.g > obgraph.mtx

${COLPACK} -f ./obgraph.mtx -o LARGEST_FIRST -m DISTANCE_ONE  > colors.txt.tmp

echo "32" > 32.txt
cat 32.txt colors.txt.tmp > colors.txt

${MPIRUN} ${GRAPH_RUN_EXE} > graph_run_log.txt

