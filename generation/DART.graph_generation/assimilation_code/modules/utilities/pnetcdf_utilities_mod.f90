! DART software - Copyright UCAR. This open source software is provided
! by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download
!
! $Id: pnetcdf_utilities_mod.f90 11289 2017-03-10 21:56:06Z hendric@ucar.edu $

module pnetcdf_utilities_mod

!> Aim: to have pnetcdf utilites in here so you don't have to 
!> always compile with pnetcdf

use utilities_mod, only : error_mesg, FATAL

use pnetcdf

implicit none

contains
!--------------------------------------------------------------
!> Check the return code from a pnetcdf call and print out information
!> if the call failed.
subroutine pnet_check(istatus, subr_name, context)

integer, intent (in)                   :: istatus !> pnetcdf return code
character(len=*), intent(in)           :: subr_name
character(len=*), intent(in), optional :: context

character(len=129) :: error_msg

! if no error, nothing to do here.  we are done.
if( istatus == NF_NOERR ) return

! something wrong.  construct an error string and call the handler.

! context is optional, but is very useful if specified.
! if context + error code > 129, the assignment will truncate.
if (present(context) ) then
   error_msg = trim(context) // ': ' // trim(nfmpi_strerror(istatus))
else
   error_msg = nfmpi_strerror(istatus)
endif

! this does not return
call error_mesg(subr_name, error_msg, FATAL)
 
end subroutine pnet_check


end module

! <next few lines under version control, do not edit>
! $URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/assimilation_code/modules/utilities/pnetcdf_utilities_mod.f90 $
! $Id: pnetcdf_utilities_mod.f90 11289 2017-03-10 21:56:06Z hendric@ucar.edu $
! $Revision: 11289 $
! $Date: 2017-03-10 14:56:06 -0700 (Fri, 10 Mar 2017) $
