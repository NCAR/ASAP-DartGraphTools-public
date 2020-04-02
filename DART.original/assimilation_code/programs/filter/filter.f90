! DART software - Copyright UCAR. This open source software is provided
! by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download
!
! $Id: filter.f90 11289 2017-03-10 21:56:06Z hendric@ucar.edu $

!> \dir filter  Main program contained here
!> \file filter.f90 Main program

program filter

!> \mainpage filter Main DART Ensemble Filtering Program
!> @{ \brief routine to perform ensemble filtering
!>

use mpi_utilities_mod, only : initialize_mpi_utilities, finalize_mpi_utilities, get_dart_mpi_comm, my_task_id, task_sync
use        filter_mod, only : filter_main
use        perf_mod ! GPTL timers

implicit none

! GPTL:
logical :: masterproc
integer :: rank
integer :: comm
integer :: maxthreads = 1

!----------------------------------------------------------------
!call vprof_start()
!call summary_start()
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
!call task_sync()
call t_startf('Total')

call filter_main()

! GPTL:
!call task_sync()
call t_stopf('Total')
call t_prf('FilterTime', comm)
call t_finalizef()

call finalize_mpi_utilities()
!call summary_stop()
!call vprof_stop()
!> @}

end program filter

! <next few lines under version control, do not edit>
! $URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/assimilation_code/programs/filter/filter.f90 $
! $Id: filter.f90 11289 2017-03-10 21:56:06Z hendric@ucar.edu $
! $Revision: 11289 $
! $Date: 2017-03-10 14:56:06 -0700 (Fri, 10 Mar 2017) $
