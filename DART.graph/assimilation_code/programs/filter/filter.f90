! DART software - Copyright UCAR. This open source software is provided
! by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download
!
! $Id$

!> \dir filter  Main program contained here
!> \file filter.f90 Main program

program filter

!> \mainpage filter Main DART Ensemble Filtering Program
!> @{ \brief routine to perform ensemble filtering
!>

use mpi_utilities_mod, only : initialize_mpi_utilities, finalize_mpi_utilities, get_dart_mpi_comm, my_task_id, task_sync
use        filter_mod, only : filter_main
use       perf_mod

implicit none

logical :: masterproc
integer :: rank
integer :: comm
!integer :: maxthreads = 1
integer :: maxthreads = 8  ! modified by bpd6 (Sep 26, 2018 - for omp version)

!----------------------------------------------------------------

call initialize_mpi_utilities('Filter')

! GPTL:
rank = my_task_id()
comm = get_dart_mpi_comm()
if (rank == 0) then
masterproc = .true.
else
masterproc = .false.
endif

! debug - bpd6
!write(*,*) "Rank = " , rank

call t_initf('input.nl',LogPrint=masterproc, Mpicom=comm, MasterTask=masterproc, maxthreads=maxthreads)
call task_sync()
call t_startf('Total')

call filter_main()

! GPTL:
call task_sync()
call t_stopf('Total')
call t_prf('FilterTime', comm)
call t_finalizef()

call finalize_mpi_utilities()

!> @}

end program filter

! <next few lines under version control, do not edit>
! $URL$
! $Id$
! $Revision$
! $Date$
