! DART software - Copyright UCAR. This open source software is provided
! by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download
!
! $Id: assim_tools_mod.f90 11799 2017-07-07 21:08:09Z nancy@ucar.edu $

!>  A variety of operations required by assimilation.
module assim_graph_tools_mod

!> \defgroup assim_tools assim_tools_mod
!> 
!> @{
use      types_mod,       only : r8, i8, digits12, PI, missing_r8
use  utilities_mod,       only : file_exist, get_unit, check_namelist_read, do_output,    &
                                 find_namelist_in_file, register_module, error_handler,   &
                                 E_ERR, E_MSG, nmlfileunit, do_nml_file, do_nml_term,     &
                                 open_file, close_file, timestamp
use       sort_mod,       only : index_sort 
use random_seq_mod,       only : random_seq_type, random_gaussian, init_random_seq,       &
                                 random_uniform

use obs_sequence_mod,     only : obs_sequence_type, obs_type, get_num_copies, get_num_qc, &
                                 init_obs, get_obs_from_key, get_obs_def, get_obs_values, &
                                 destroy_obs, get_obs_from_key_debug
   
use          obs_def_mod, only : obs_def_type, get_obs_def_location, get_obs_def_time,    &
                                 get_obs_def_error_variance, get_obs_def_type_of_obs

use         obs_kind_mod, only : get_num_types_of_obs, get_index_for_type_of_obs,                   &
                                 get_quantity_for_type_of_obs, assimilate_this_type_of_obs

use       cov_cutoff_mod, only : comp_cov_factor

use       reg_factor_mod, only : comp_reg_factor

use       obs_impact_mod, only : allocate_impact_table, read_impact_table, free_impact_table

use sampling_error_correction_mod, only : get_sampling_error_table_size, &
                                          read_sampling_error_correction

use         location_mod, only : location_type, get_close_type, query_location,           &
                                 operator(==), set_location_missing, write_location,      &
                                 LocationDims, is_vertical, vertical_localization_on,     &
                                 set_vertical, has_vertical_choice, get_close_init,       &
                                 get_vertical_localization_coord, get_close_destroy,      &
                                 set_vertical_localization_coord

use ensemble_manager_mod, only : ensemble_type, get_my_num_vars, get_my_vars,             & 
                                 compute_copy_mean_var, get_var_owner_index,              &
                                 prepare_to_update_copies, map_pe_to_task

use mpi_utilities_mod,    only : my_task_id, broadcast_send, broadcast_recv,              & 
                                 sum_across_tasks, task_count, start_mpi_timer,           &
                                 read_mpi_timer, task_sync, task_sync_filter, task_sync_final

use adaptive_inflate_mod, only : do_obs_inflate,  do_single_ss_inflate,                   &
                                 do_varying_ss_inflate,                                   &
                                 update_inflation,                                        &
                                 inflate_ens, adaptive_inflate_type,                      &
                                 deterministic_inflate, solve_quadratic

use time_manager_mod,     only : time_type, get_time

use assim_model_mod,      only : get_state_meta_data,                                     &
                                 get_close_obs,         get_close_state,                  &
                                 convert_vertical_obs,  convert_vertical_state

use distributed_state_mod, only : create_mean_window, free_mean_window

use quality_control_mod, only : good_dart_qc, DARTQC_FAILED_VERT_CONVERT

use perf_mod

implicit none
private

public ::  filter_assim, &
          set_assim_tools_trace, &
          get_missing_ok_status, &
          test_state_copies, &
          update_ens_from_weights  ! Jeff thinks this routine is in the wild.

! Indicates if module initialization subroutine has been called yet
logical :: module_initialized = .false.

integer :: print_timestamps    = 0
integer :: print_trace_details = 0

! True if random sequence needs to be initialized
logical                :: first_inc_ran_call = .true.
type (random_seq_type) :: inc_ran_seq

integer                :: num_types = 0
real(r8), allocatable  :: cutoff_list(:)
logical                :: has_special_cutoffs
logical                :: close_obs_caching = .true.  
! Modified by bpd6 on May 7th to test issue with caching.  ERROR
!logical                :: close_obs_caching = .false.
real(r8), parameter    :: small = epsilon(1.0_r8)   ! threshold for avoiding NaNs/Inf

! true if we have multiple vert choices and we're doing vertical localization
! (make it a local variable so we don't keep making subroutine calls)
logical                :: is_doing_vertical_conversion = .false.

character(len = 255)   :: msgstring, msgstring2, msgstring3

! Need to read in table for off-line based sampling correction and store it
integer                :: sec_table_size
real(r8), allocatable  :: exp_true_correl(:), alpha(:)

! if adjust_obs_impact is true, read in triplets from the ascii file
! and fill this 2d impact table. 
real(r8), allocatable  :: obs_impact_table(:,:)

! version controlled file description for error handling, do not edit
character(len=256), parameter :: source   = &
   "$URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/assimilation_code/modules/assimilation/assim_tools_mod.f90 $"
character(len=32 ), parameter :: revision = "$Revision: 11799 $"
character(len=128), parameter :: revdate  = "$Date: 2017-07-07 15:08:09 -0600 (Fri, 07 Jul 2017) $"


!! bpd6 colors:
type colors_type
   character(len=200) :: coloring_file ! Static for now, add to namelist later?  

   integer :: chunk_size  ! Read from namelist (set to default for now)
   integer :: num_colors  ! Calculated from data

   integer, dimension(:), allocatable :: obs_color ! Color of 1-n observations (read from data)

!   integer, dimension(:), allocatable :: owner       ! Rank that owns this observation (computed from data)
end type colors_type

integer, parameter :: max_chunk_size = 256! for now
type chunk_type
    integer :: num_obs
    integer :: owner
    integer :: comm_obs
    integer :: comm_size

    integer, dimension(max_chunk_size) :: obs_list
end type chunk_type

type chunk_data_type
   integer :: num_obs
   real(r8), dimension(:,:), allocatable :: obs_prior ! (ob in chunk, ens size)
   real(r8), dimension(:,:), allocatable :: obs_inc
   real(r8), dimension(:,:), allocatable :: net_a     ! (ob in chunk, num_groups)
   real(r8), dimension(:), allocatable   :: obs_qc
   real(r8), dimension(:), allocatable   :: vertvalue_obs_in_localization_coord
   real(r8), dimension(:), allocatable   :: whichvert_real

   !type(location_type), dimension(:), allocatable  :: base_obs_loc

   real(r8), dimension(:), allocatable :: bcast_buffer
   integer :: comm_obs
   integer :: comm_size
end type chunk_data_type

!============================================================================

!---- namelist with default values

! Filter kind selects type of observation space filter
!      1 = EAKF filter
!      2 = ENKF
!      3 = Kernel filter
!      4 = particle filter
!      5 = random draw from posterior
!      6 = deterministic draw from posterior with fixed kurtosis
!      8 = Rank Histogram Filter (see Anderson 2011)
!
!  special_localization_obs_types -> Special treatment for the specified observation types
!  special_localization_cutoffs   -> Different cutoff value for each specified obs type
!
integer  :: filter_kind                     = 1
real(r8) :: cutoff                          = 0.2_r8
logical  :: sort_obs_inc                    = .false.
logical  :: spread_restoration              = .false.
logical  :: sampling_error_correction       = .false.
integer  :: adaptive_localization_threshold = -1
real(r8) :: adaptive_cutoff_floor           = 0.0_r8
integer  :: print_every_nth_obs             = 0

! since this is in the namelist, it has to have a fixed size.
integer, parameter   :: MAX_ITEMS = 300
character(len = 129) :: special_localization_obs_types(MAX_ITEMS)
real(r8)             :: special_localization_cutoffs(MAX_ITEMS)

logical              :: output_localization_diagnostics = .false.
character(len = 129) :: localization_diagnostics_file = "localization_diagnostics"

! Following only relevant for filter_kind = 8
logical  :: rectangular_quadrature          = .true.
logical  :: gaussian_likelihood_tails       = .false.

! Some models are allowed to have MISSING_R8 values in the DART state vector.
! If they are encountered, it is not necessarily a FATAL error.
! Most of the time, if a MISSING_R8 is encountered, DART should die.
! CLM should have allow_missing_in_clm = .true.
! maybe POP - but in POP the missing values are land and all ensemble members
! have the same missing values.  CLM is different in that only some ensemble members may
! have missing values and so we have a deficient ensemble size at those state locations.
logical  :: allow_missing_in_clm = .false.

! False by default; if true, expect to read in an ascii table
! to adjust the impact of obs on other state vector and obs values.
logical            :: adjust_obs_impact  = .false.
character(len=256) :: obs_impact_filename = ''
logical            :: allow_any_impact_values = .false.

! These next two only affect models with multiple options
! for vertical localization:
!
! "convert_state" is false by default; it depends on the model
! what is faster - do the entire state up front and possibly
! do unneeded work, or do the conversion during the assimilation
! loop. we think this depends heavily on how much of the state
! is going to be adjusted by the obs.  for a global model
! we think false may be better; for a regional model with
! a lot of obs and full coverage true may be better.
!
! "convert_obs" is true by default; in general it seems to
! be better for each task to convert the obs vertical before
! going into the loop but again this depends on how many
! obs per task and whether the mean is distributed or 
! replicated on each task.
logical :: convert_all_state_verticals_first = .false.
logical :: convert_all_obs_verticals_first   = .true.

! Not in the namelist; this var disables the experimental
! linear and spherical case code in the adaptive localization 
! sections.  to try out the alternatives, set this to .false.
logical  :: only_area_adapt  = .true.

! Option to distribute the mean.  If 'false' each task will have a full
! copy of the ensemble mean, which speeds models doing vertical conversion.
! If 'true' the mean will be spread across all tasks which reduces the
! memory needed per task but requires communication if the mean is used
! for vertical conversion.  We have changed the default to be .false.
! compared to previous versions of this namelist item.
logical  :: distribute_mean  = .false.
!logical  :: distribute_mean  = .true.  ! this causes hangs?  weird (BPD6)

! Lanai bitwise. This is for unit testing and runs much slower.
! Only use for when testing against the non-rma trunk.
logical  :: lanai_bitwise = .false.


! Changes by bpd6
logical :: sync_between_timers = .false.
logical :: packed_sends = .true.
logical :: detailed_timers = .false.
logical :: debug_mode = .false.

namelist / assim_tools_nml / filter_kind, cutoff, sort_obs_inc, &
   spread_restoration, sampling_error_correction,                          & 
   adaptive_localization_threshold, adaptive_cutoff_floor,                 &
   print_every_nth_obs, rectangular_quadrature, gaussian_likelihood_tails, &
   output_localization_diagnostics, localization_diagnostics_file,         &
   special_localization_obs_types, special_localization_cutoffs,           &
   allow_missing_in_clm, distribute_mean, close_obs_caching,               &
   adjust_obs_impact, obs_impact_filename, allow_any_impact_values,        &
   convert_all_state_verticals_first, convert_all_obs_verticals_first,     &
   sync_between_timers, packed_sends, detailed_timers, debug_mode, &  ! Modifications by bpd6
   lanai_bitwise ! don't document this one -- only used for regression tests

!============================================================================

contains

!-------------------------------------------------------------

subroutine assim_tools_init()

integer :: iunit, io, i, j
integer :: num_special_cutoff, type_index
logical :: cache_override = .false.

call register_module(source, revision, revdate)

! do this up front
module_initialized = .true.

! give these guys initial values at runtime *before* we read
! in the namelist.  this is to help detect how many items are
! actually given in the namelist.
special_localization_obs_types(:)  = 'null'
special_localization_cutoffs(:)    =  missing_r8 

! Read the namelist entry
call find_namelist_in_file("input.nml", "assim_tools_nml", iunit)
read(iunit, nml = assim_tools_nml, iostat = io)
call check_namelist_read(iunit, io, "assim_tools_nml")

! Write the namelist values to the log file
if (do_nml_file()) write(nmlfileunit, nml=assim_tools_nml)
if (do_nml_term()) write(     *     , nml=assim_tools_nml)

! Forcing distributed_mean for single processor.
! Note null_win_mod.f90 ignores distibute_mean.
if (task_count() == 1) distribute_mean = .true.

! FOR NOW, can only do spread restoration with filter option 1 (need to extend this)
if(spread_restoration .and. .not. filter_kind == 1) then
   write(msgstring, *) 'cannot combine spread_restoration and filter_kind ', filter_kind
   call error_handler(E_ERR,'assim_tools_init:', msgstring, source, revision, revdate)
endif

! allocate a list in all cases - even the ones where there is only
! a single cutoff value.  note that in spite of the name these
! are specific types (e.g. RADIOSONDE_TEMPERATURE, AIRCRAFT_TEMPERATURE)
! because that's what get_close() is passed.   and because i've confused
! myself several times -- we define generic kinds starting at 0, but
! the specific types are autogenerated and always start at 1.  so the
! cutoff list is never (0:num_types); it is always (num_types).
num_types = get_num_types_of_obs()
allocate(cutoff_list(num_types)) 
cutoff_list(:) = cutoff
has_special_cutoffs = .false.

! Go through special-treatment observation kinds, if any.
num_special_cutoff = 0
j = 0
do i = 1, MAX_ITEMS
   if(special_localization_obs_types(i) == 'null') exit
   if(special_localization_cutoffs(i) == MISSING_R8) then
      write(msgstring, *) 'cutoff value', i, ' is uninitialized.'
      call error_handler(E_ERR,'assim_tools_init:', &
                         'special cutoff namelist for types and distances do not match', &
                         source, revision, revdate, &
                         text2='kind = '//trim(special_localization_obs_types(i)), &
                         text3=trim(msgstring))
   endif
   j = j + 1
enddo
num_special_cutoff = j

if (num_special_cutoff > 0) has_special_cutoffs = .true.

do i = 1, num_special_cutoff
   type_index = get_index_for_type_of_obs(special_localization_obs_types(i))
   if (type_index < 0) then
      write(msgstring, *) 'unrecognized TYPE_ in the special localization namelist:'
      call error_handler(E_ERR,'assim_tools_init:', msgstring, source, revision, revdate, &
                         text2=trim(special_localization_obs_types(i)))
   endif
   cutoff_list(type_index) = special_localization_cutoffs(i)
end do

! cannot cache previous obs location if different obs types have different
! localization radii.  change it to false, and warn user why.
if (has_special_cutoffs .and. close_obs_caching) then
   cache_override = .true.
   close_obs_caching = .false.
endif

if(sampling_error_correction) then
   sec_table_size = get_sampling_error_table_size()
   allocate(exp_true_correl(sec_table_size), alpha(sec_table_size))
   ! we can't read the table here because we don't have access to the ens_size
endif

is_doing_vertical_conversion = (has_vertical_choice() .and. vertical_localization_on() .and. &
                                .not. lanai_bitwise)

call log_namelist_selections(num_special_cutoff, cache_override)

end subroutine assim_tools_init

!-------------------------------------------------------------

subroutine filter_assim(ens_handle, obs_ens_handle, obs_seq, keys,           &
   ens_size, num_groups, obs_val_index, inflate, ENS_MEAN_COPY, ENS_SD_COPY, &
   ENS_INF_COPY, ENS_INF_SD_COPY, OBS_KEY_COPY, OBS_GLOBAL_QC_COPY,          &
   OBS_PRIOR_MEAN_START, OBS_PRIOR_MEAN_END, OBS_PRIOR_VAR_START,            &
   OBS_PRIOR_VAR_END, inflate_only)
use mpi
!use ifport
type(ensemble_type),         intent(inout) :: ens_handle, obs_ens_handle
type(obs_sequence_type),     intent(in)    :: obs_seq
integer,                     intent(in)    :: keys(:)
integer,                     intent(in)    :: ens_size, num_groups, obs_val_index
type(adaptive_inflate_type), intent(inout) :: inflate
integer,                     intent(in)    :: ENS_MEAN_COPY, ENS_SD_COPY, ENS_INF_COPY
integer,                     intent(in)    :: ENS_INF_SD_COPY
integer,                     intent(in)    :: OBS_KEY_COPY, OBS_GLOBAL_QC_COPY
integer,                     intent(in)    :: OBS_PRIOR_MEAN_START, OBS_PRIOR_MEAN_END
integer,                     intent(in)    :: OBS_PRIOR_VAR_START, OBS_PRIOR_VAR_END
logical,                     intent(in)    :: inflate_only

!>@todo FIXME this routine has a huge amount of local/stack storage.
!>at some point does it need to be allocated instead?  this routine isn't
!>called frequently so doing allocate/deallocate isn't a timing issue.  
!>putting arrays on the stack is fast, but risks running out of stack space 
!>and dying with strange errors.

real(r8) :: obs_prior(ens_size), obs_inc(ens_size), increment(ens_size)
real(r8) :: reg_factor, impact_factor
real(r8) :: net_a(num_groups), reg_coef(num_groups), correl(num_groups)
real(r8) :: cov_factor, obs(1), obs_err_var, my_inflate, my_inflate_sd
real(r8) :: varying_ss_inflate, varying_ss_inflate_sd
real(r8) :: ss_inflate_base, obs_qc, cutoff_rev, cutoff_orig
real(r8) :: gamma, ens_obs_mean, ens_obs_var, ens_var_deflate
real(r8) :: r_mean, r_var
real(r8) :: orig_obs_prior_mean(num_groups), orig_obs_prior_var(num_groups)
real(r8) :: obs_prior_mean(num_groups), obs_prior_var(num_groups)
real(r8) :: close_obs_dist(obs_ens_handle%my_num_vars)
real(r8) :: close_state_dist(ens_handle%my_num_vars)
real(r8) :: last_close_obs_dist(obs_ens_handle%my_num_vars)
real(r8) :: last_close_state_dist(ens_handle%my_num_vars)
real(r8) :: diff_sd, outlier_ratio

integer(i8) :: state_index
integer(i8) :: my_state_indx(ens_handle%my_num_vars)
integer(i8) :: my_obs_indx(obs_ens_handle%my_num_vars)

integer  :: my_num_obs, i, j, owner, owners_index, my_num_state
integer  :: this_obs_key, obs_mean_index, obs_var_index
integer  :: grp_beg(num_groups), grp_end(num_groups), grp_size, grp_bot, grp_top, group
integer  :: close_obs_ind(obs_ens_handle%my_num_vars)
integer  :: close_state_ind(ens_handle%my_num_vars)
integer  :: last_close_obs_ind(obs_ens_handle%my_num_vars)
integer  :: last_close_state_ind(ens_handle%my_num_vars)
integer  :: num_close_obs, obs_index, num_close_states
integer  :: total_num_close_obs, last_num_close_obs, last_num_close_states
integer  :: base_obs_kind, base_obs_type, my_obs_kind(obs_ens_handle%my_num_vars)
integer  :: my_obs_type(obs_ens_handle%my_num_vars)
integer  :: my_state_kind(ens_handle%my_num_vars), nth_obs
integer  :: num_close_obs_cached, num_close_states_cached
integer  :: num_close_obs_calls_made, num_close_states_calls_made
! GSR add new count for only the 'assimilate' type close obs in the tile
integer  :: localization_unit, secs, days, rev_num_close_obs
character(len = 102)  :: base_loc_text   ! longest location formatting possible

type(location_type)  :: my_obs_loc(obs_ens_handle%my_num_vars)
type(location_type)  :: base_obs_loc, last_base_obs_loc, last_base_states_loc
type(location_type)  :: my_state_loc(ens_handle%my_num_vars), dummyloc
type(get_close_type) :: gc_obs, gc_state
type(obs_type)       :: observation

integer :: last_rank

type(obs_def_type)   :: obs_def
type(time_type)      :: obs_time, this_obs_time

logical :: do_adapt_inf_update
logical :: missing_in_state
! for performance, local copies 
logical :: local_single_ss_inflate
logical :: local_varying_ss_inflate
logical :: local_obs_inflate

! HK observation location conversion
real(r8) :: vertvalue_obs_in_localization_coord
integer  :: whichvert_obs_in_localization_coord
real(r8) :: whichvert_real
type(location_type) :: lc(1)
integer             :: kd(1)

! timing - set one or both of the parameters to true
! to get timing info printed out.
real(digits12) :: base, elapsed, base2
logical, parameter :: timing = .false.
logical, parameter :: timing1 = .false.
real(digits12), allocatable :: elapse_array(:)

integer :: istatus 
integer :: vstatus(obs_ens_handle%my_num_vars) !< for vertical conversion status.

! bpd6
type(colors_type) :: colors
integer :: histogram_unit ! bpd6
integer :: list_unit ! bpd6
integer :: obdata_unit ! bpd6
integer :: obdata_unit2 ! bpd6
character(len = 129) :: histogram_file = "histogram_data.txt"
character(len = 129) :: list_file = "list_data.txt"
character(len = 129) :: colors_file = "colors.txt"

! new mods, 2018-01-16:
character(len = 129) :: obdata_file = "obdata.txt"
character(len = 129) :: obdata_file2 = "obdata2.txt"

integer  :: total_close_ranks, rev_close_ranks

integer :: qcd = 0 ! bpd6
integer :: iError
real(r8) :: testval, testval2
integer :: k

integer :: skipped_missing = 0
integer :: skipped_covfactor = 0
real(r8) :: stateupdate_time = 0.0d0
INTEGER(kind=8) :: timer_count, timer_rate, timer_max
INTEGER(kind=8) :: timer_count2, timer_rate2, timer_max2


! bpd6 - more debugging values
real(kind=8) :: increment_sum, increment_total
real(kind=8) :: regfactor_sum, regfactor_total
integer(kind=8) :: stateindex_sum, stateindex_total

integer :: skipped_missing_total, skipped_covfactor_total
integer :: num_close_states_total, num_close_obs_total

! coloring - bpd6
!logical :: own_color
!integer :: obs_set_size
!integer, dimension(8000) :: obs_set
!integer, dimension(:), allocatable :: obs_list
type(chunk_type), dimension(:), allocatable :: chunks

integer :: original_chunk_size


type(chunk_data_type) chunk_data

integer (kind=8) :: ob_index
integer :: debug_loop

!debug
real(kind=8) :: checksum, checksum_total

integer :: mythread
integer :: OMP_GET_THREAD_NUM
integer :: OMP_GET_NUM_THREADS

!packed sends (into a buffer)?
!logical :: packed_sends = .true.

! synchronize between timers?
!logical :: sync_between_timers = .false.

! trace files:
open(unit=15, file="trace.1")
open(unit=16, file="trace.2")

!checksum = sum(obs_ens_handle%copies(1:ens_size,:))
!call MPI_Reduce(checksum, checksum_total, 1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!if (my_task_id() == 0) then
!   write(*,*) "PreCheck0: ", checksum_total
!endif

!call task_sync()
call task_sync()
call t_startf('ASSIMILATE:Pre.Loop')

! we are going to read/write the copies array
call prepare_to_update_copies(ens_handle)
call prepare_to_update_copies(obs_ens_handle)

! Initialize assim_tools_module if needed
if (.not. module_initialized) call assim_tools_init()

!HK make window for mpi one-sided communication
! used for vertical conversion in get_close_obs
! Need to give create_mean_window the mean copy
!write(*,*) "Setup: Calling create_mean_window w/ ens_handle"
!call create_mean_window(ens_handle, ENS_MEAN_COPY, distribute_mean, graph=.true.)
call create_mean_window(ens_handle, ENS_MEAN_COPY, distribute_mean)  ! Just use ens_handle%distribution type?

! filter kinds 1 and 8 return sorted increments, however non-deterministic
! inflation can scramble these. the sort is expensive, so help users get better 
! performance by rejecting namelist combinations that do unneeded work.
if (sort_obs_inc) then
   if(deterministic_inflate(inflate) .and. ((filter_kind == 1) .or. (filter_kind == 8))) then
      write(msgstring,  *) 'With a deterministic filter [assim_tools_nml:filter_kind = ',filter_kind,']'
      write(msgstring2, *) 'and deterministic inflation [filter_nml:inf_deterministic = .TRUE.]'
      write(msgstring3, *) 'assim_tools_nml:sort_obs_inc = .TRUE. is not needed and is expensive.'
      call error_handler(E_MSG,'', '')  ! whitespace
      call error_handler(E_MSG,'WARNING filter_assim:', msgstring, source, revision, revdate, &
                         text2=msgstring2,text3=msgstring3)
      call error_handler(E_MSG,'', '')  ! whitespace
      sort_obs_inc = .FALSE.
   endif
endif

if (my_task_id() == 0) then
  histogram_unit = open_file(histogram_file) ! bpd6
  list_unit = open_file(list_file) ! bpd6
  obdata_unit = open_file(obdata_file) ! bpd6 ! New, 2018-01-16
  obdata_unit2 = open_file(obdata_file2) ! bpd6 ! New, 2018-01-16
endif

!GSR open the dignostics file
if(output_localization_diagnostics .and. my_task_id() == 0) then
  localization_unit = open_file(localization_diagnostics_file, action = 'append')
endif

! For performance, make local copies of these settings which
! are really in the inflate derived type.
local_single_ss_inflate  = do_single_ss_inflate(inflate)
local_varying_ss_inflate = do_varying_ss_inflate(inflate)
local_obs_inflate        = do_obs_inflate(inflate)

! Default to printing nothing
nth_obs = -1

! Divide ensemble into num_groups groups.
! make sure the number of groups and ensemble size result in 
! at least 2 members in each group (to avoid divide by 0) and 
! that the groups all have the same number of members.
grp_size = ens_size / num_groups
if ((grp_size * num_groups) /= ens_size) then
   write(msgstring,  *) 'The number of ensemble members must divide into the number of groups evenly.'
   write(msgstring2, *) 'Ensemble size = ', ens_size, '  Number of groups = ', num_groups
   write(msgstring3, *) 'Change number of groups or ensemble size to avoid remainders.'
   call error_handler(E_ERR,'filter_assim:', msgstring, source, revision, revdate, &
                         text2=msgstring2,text3=msgstring3)
endif
if (grp_size < 2) then
   write(msgstring,  *) 'There must be at least 2 ensemble members in each group.'
   write(msgstring2, *) 'Ensemble size = ', ens_size, '  Number of groups = ', num_groups
   write(msgstring3, *) 'results in < 2 members/group.  Decrease number of groups or increase ensemble size'
   call error_handler(E_ERR,'filter_assim:', msgstring, source, revision, revdate, &
                         text2=msgstring2,text3=msgstring3)
endif
do group = 1, num_groups
   grp_beg(group) = (group - 1) * grp_size + 1
   grp_end(group) = grp_beg(group) + grp_size - 1
enddo

! Put initial value of state space inflation in copy normally used for SD
! This is to avoid weird storage footprint in filter
ens_handle%copies(ENS_SD_COPY, :) = ens_handle%copies(ENS_INF_COPY, :)

! For single state or obs space inflation, the inflation is like a token
! Gets passed from the processor with a given obs on to the next
if(local_single_ss_inflate) then
   my_inflate    = ens_handle%copies(ENS_INF_COPY,    1)
   my_inflate_sd = ens_handle%copies(ENS_INF_SD_COPY, 1)
end if


! Get info on my number and indices for obs
my_num_obs = get_my_num_vars(obs_ens_handle)
call get_my_vars(obs_ens_handle, my_obs_indx)

! Construct an observation temporary
call init_obs(observation, get_num_copies(obs_seq), get_num_qc(obs_seq))

! Get the locations for all of my observations 
! HK I would like to move this to before the calculation of the forward operator so you could
! overwrite the vertical location with the required localization vertical coordinate when you 
! do the forward operator calculation
call get_my_obs_loc(ens_handle, obs_ens_handle, obs_seq, keys, my_obs_loc, my_obs_kind, my_obs_type, obs_time)
!do iError = 1, obs_ens_handle%my_num_vars
!  write(*,*) "Loc : ", obs_ens_handle%my_vars(iError), my_obs_loc(iError)%lon, my_obs_loc(iError)%lat
!enddo

if (convert_all_obs_verticals_first .and. is_doing_vertical_conversion) then
   ! convert the vertical of all my observations to the localization coordinate
   ! this may not be bitwise with Lanai because of a different number of set_location calls
   if (timing) call start_mpi_timer(base)
   call convert_vertical_obs(ens_handle, obs_ens_handle%my_num_vars, my_obs_loc, &
                             my_obs_kind, my_obs_type, get_vertical_localization_coord(), vstatus)
   do i = 1, obs_ens_handle%my_num_vars
      if (good_dart_qc(nint(obs_ens_handle%copies(OBS_GLOBAL_QC_COPY, i)))) then
         !> @todo Can I just use the OBS_GLOBAL_QC_COPY? Is it ok to skip the loop?
         if (vstatus(i) /= 0) obs_ens_handle%copies(OBS_GLOBAL_QC_COPY, i) = DARTQC_FAILED_VERT_CONVERT
      endif
   enddo
   if (timing) then
      elapsed = read_mpi_timer(base)
      print*, 'convert_vertical_obs time :', elapsed, 'rank ', my_task_id()
   endif
endif

! Get info on my number and indices for state
my_num_state = get_my_num_vars(ens_handle)
call get_my_vars(ens_handle, my_state_indx)

! Get the location and kind of all my state variables
if (timing) call start_mpi_timer(base)
do i = 1, ens_handle%my_num_vars
   call get_state_meta_data(my_state_indx(i), my_state_loc(i), my_state_kind(i))
end do
if (timing) then
   elapsed = read_mpi_timer(base)
   print*, 'get_state_meta_data time :', elapsed, 'rank ', my_task_id()
endif

!call test_get_state_meta_data(my_state_loc, ens_handle%my_num_vars)

!> optionally convert all state location verticals
if (convert_all_state_verticals_first .and. is_doing_vertical_conversion) then
   if (timing) call start_mpi_timer(base)
   call convert_vertical_state(ens_handle, ens_handle%my_num_vars, my_state_loc, my_state_kind,  &
                                            my_state_indx, get_vertical_localization_coord(), istatus)
   if (timing) then
      elapsed = read_mpi_timer(base)
      print*, 'convert_vertical_state time :', elapsed, 'rank ', my_task_id()
   endif
endif

! PAR: MIGHT BE BETTER TO HAVE ONE PE DEDICATED TO COMPUTING 
! INCREMENTS. OWNING PE WOULD SHIP IT'S PRIOR TO THIS ONE
! BEFORE EACH INCREMENT.

! Get mean and variance of each group's observation priors for adaptive inflation
! Important that these be from before any observations have been used
if(local_varying_ss_inflate .or. local_single_ss_inflate) then
   do group = 1, num_groups
      obs_mean_index = OBS_PRIOR_MEAN_START + group - 1
      obs_var_index  = OBS_PRIOR_VAR_START  + group - 1
         call compute_copy_mean_var(obs_ens_handle, grp_beg(group), grp_end(group), &
           obs_mean_index, obs_var_index) 
   end do
endif

! The computations in the two get_close_maxdist_init are redundant

! Initialize the method for getting state variables close to a given ob on my process
if (has_special_cutoffs) then
   call get_close_init(gc_state, my_num_state, 2.0_r8*cutoff, my_state_loc, 2.0_r8*cutoff_list)
else
   call get_close_init(gc_state, my_num_state, 2.0_r8*cutoff, my_state_loc)
endif

! Initialize the method for getting obs close to a given ob on my process
if (has_special_cutoffs) then
   call get_close_init(gc_obs, my_num_obs, 2.0_r8*cutoff, my_obs_loc, 2.0_r8*cutoff_list)
else
   call get_close_init(gc_obs, my_num_obs, 2.0_r8*cutoff, my_obs_loc)
endif

if (close_obs_caching) then
   ! Initialize last obs and state get_close lookups, to take advantage below 
   ! of sequential observations at the same location (e.g. U,V, possibly T,Q)
   ! (this is getting long enough it probably should go into a subroutine. nsc.)
   last_base_obs_loc           = set_location_missing()
   last_base_states_loc        = set_location_missing()
   last_num_close_obs          = -1
   last_num_close_states       = -1
   last_close_obs_ind(:)       = -1
   last_close_state_ind(:)     = -1
   last_close_obs_dist(:)      = 888888.0_r8   ! something big, not small
   last_close_state_dist(:)    = 888888.0_r8   ! ditto
   num_close_obs_cached        = 0
   num_close_states_cached     = 0
   num_close_obs_calls_made    = 0
   num_close_states_calls_made = 0
endif



!bpd6 - get the coloring info
call read_obs_colors(colors_file, obs_ens_handle%num_vars, colors)
call create_chunks(colors, chunks)
call initialize_chunk_data(colors%chunk_size, ens_size, num_groups, chunk_data)

! timing
if (my_task_id() == 0 .and. timing) allocate(elapse_array(obs_ens_handle%num_vars))


call t_stopf('ASSIMILATE:Pre.Loop')

! Loop through all the chunks:
!write(*,*) "[Info] Number of Chunks = ", size(chunks)
nth_obs = size(chunks) / 100
if (nth_obs == 0) then 
  nth_obs = 1
endif

if (my_task_id() == 0) then
   write(*,*) "Number of chunks : ", size(chunks)
endif

if (sync_between_timers) then
  call task_sync()
endif

  !! New functionality - compute the num obs on ALL procs, outside the loop
  call t_startf('QC_Prep_Loop')
  do i = 1, size(chunks)
    original_chunk_size = chunks(i)%num_obs
    chunks(i)%comm_obs = chunks(i)%num_obs
    do j = 1, original_chunk_size
       ob_index = chunks(i)%obs_list(j)
       owner = chunks(i)%owner
       if (my_task_id() == owner) then
         owners_index = graph_owners_index(chunks, i, j) 
         obs_qc = obs_ens_handle%copies(OBS_GLOBAL_QC_COPY, owners_index)
         call MPI_Bcast(obs_qc, 1, MPI_DOUBLE_PRECISION, owner, MPI_COMM_WORLD, iError) 
       else
         call MPI_Bcast(obs_qc, 1, MPI_DOUBLE_PRECISION, owner, MPI_COMM_WORLD, iError) 
       endif
       ! Now everyone has the QC value
       if (nint(obs_qc) /= 0) then
           chunks(i)%comm_obs = chunks(i)%comm_obs - 1
       endif
     end do
     chunks(i)%comm_size = (chunks(i)%comm_obs * ens_size * 2) + (chunks(i)%comm_obs * num_groups) + (chunks(i)%comm_obs * 3) + 1 
  end do
  call t_stopf('QC_Prep_Loop')

if (sync_between_timers) then
  call task_sync()
endif

call t_startf('Full Loop')

CHUNK_LOOP: do i = 1, size(chunks)
   call t_startf('ASSIMILATE:Header')
   if (debug_mode) then
      if (my_task_id() == 0) then
        write(*,'(A5,I6,A7,I6,A4,I6,A3,I9,A3,I9)') "Rank",my_task_id(),"C#",i,"Own",chunks(i)%owner,"St",chunks(i)%obs_list(1),"En",chunks(i)%obs_list(chunks(i)%num_obs)
      endif
   endif

   if (mod(i,nth_obs) == 0) then
       if (my_task_id() == 0) then
        write(*,'(A5,I6,A7,I6,A4,I6,A3,I9,A3,I9)') "Rank",my_task_id(),"C#",i,"Own",chunks(i)%owner,"St",chunks(i)%obs_list(1),"En",chunks(i)%obs_list(chunks(i)%num_obs)
       endif
   endif

    chunk_data%num_obs = chunks(i)%num_obs
    chunk_data%comm_obs = chunks(i)%comm_obs
    chunk_data%comm_size = chunks(i)%comm_size
   ! This section is only done by one process - the 'owner' of this chunk:
   call t_stopf('ASSIMILATE:Header')
   if (sync_between_timers) then
       call task_sync_filter('SYNC:Header')
   endif
   if (ens_handle%my_pe == chunks(i)%owner) then
      call t_startf('ASSIMILATE:Owned(Compute)')

      OBS_LOOP: do j = 1, chunk_data%num_obs
         !write(*,*) "Ob loop : ", j, chunk_data%num_obs
        ! Get the index of this ob into the main sequence:
        ob_index = chunks(i)%obs_list(j)

        !write(*,*) "ob_index = ", ob_index, i, j



        ! Get owners index: (?) - we ignore owner here, so this can be changed,
        ! but need to understand it better first.
        !!!! call get_var_owner_index(int(ob_index,i8), owner, owners_index)
        !! Commented out the above for now, and replacing with simple mapping to
        !test correctness on >1 core:
        owner = chunks(i)%owner
        !owners_index = j
        call t_startf('GraphOwnerIndex')
        owners_index = graph_owners_index(chunks, i, j) ! This can be optimized
        call t_stopf('GraphOwnerIndex')
        !write(*,*) "DEBUG: Ob_Index  = ", int(ob_index,i8), owner, owners_index

        ! Get the QC value for this ob:
        chunk_data%obs_qc(j) = obs_ens_handle%copies(OBS_GLOBAL_QC_COPY, owners_index)

        ! Only value of 0 for DART QC field should be assimilated
        IF_QC_IS_OKAY: if(nint(chunk_data%obs_qc(j)) ==0 ) then
           chunk_data%obs_prior(:,j) = obs_ens_handle%copies(1:ens_size, owners_index)

           do group = 1, num_groups
              grp_bot = grp_beg(group)
              grp_top = grp_end(group)
              !write(*,*) "Obs_Prior(A) : ", j,sum(chunk_data%obs_prior(j,grp_bot:grp_top)), owners_index
           end do
           !write(*,*) "DEBUG : obs_prior_sum = ", sum(chunk_data%obs_prior(j,:)), chunks(i)%obs_list(j)

           ! Compute the prior mean and variance for this observation
           orig_obs_prior_mean = obs_ens_handle%copies(OBS_PRIOR_MEAN_START: OBS_PRIOR_MEAN_END, owners_index) ! unused for now,
           orig_obs_prior_var  = obs_ens_handle%copies(OBS_PRIOR_VAR_START:  OBS_PRIOR_VAR_END, owners_index)  ! unused for now
 
           ! Get the value of the observation
           !call get_obs_from_key(obs_seq, keys(ob_index), observation)
           call get_obs_from_key_debug(obs_seq, keys(ob_index), observation, i, j, my_task_id()) ! bpd6 for debugging
           call get_obs_def(observation, obs_def)
           call get_obs_values(observation, obs, obs_val_index)
           obs_err_var = get_obs_def_error_variance(obs_def)  ! Add to the chunk data type?


           ! Compute observation space increments for each group
           do group = 1, num_groups
              grp_bot = grp_beg(group)
              grp_top = grp_end(group)
              call obs_increment(chunk_data%obs_prior(grp_bot:grp_top,j), grp_size, obs(1), obs_err_var, chunk_data%obs_inc(grp_bot:grp_top,j), inflate, my_inflate, my_inflate_sd, chunk_data%net_a(group,j))
           end do

           ! ------- NOTE: Skipping SINGLE_SS_INFLATE section for now -------
         endif IF_QC_IS_OKAY

         ! ----- NOTE: Skipping vertical conversion section for now ------

     enddo OBS_LOOP
     ! Haven't implemented the two other kinds of broadcasts yet, so no 'if' here:
     !!!call broadcast_send(map_pe_to_task(ens_handle, owner), obs_prior, obs_inc, net_a, scalar1=obs_qc, scalar2=vertvalue_obs_in_localization_coord, scalar3=whichvert_real)

    call t_stopf('ASSIMILATE:Owned(Compute)')
    if (sync_between_timers) then
      call task_sync_filter('SYNC:Owned(Compute)')
    endif
    call t_startf('ASSIMILATE:Owned(Broadcast)')

     !write(*,*) "Calling broadcast_send_chunk on owner", chunks(i)%owner
    if (packed_sends) then
      call broadcast_send_chunk_packed_opt(map_pe_to_task(ens_handle, chunks(i)%owner), chunk_data, ens_size, num_groups)
    else
      call broadcast_send_chunk(map_pe_to_task(ens_handle, chunks(i)%owner), chunk_data)
    endif
    call t_stopf('ASSIMILATE:Owned(Broadcast)')

    if (sync_between_timers) then
      call task_sync_filter('SYNC:Owned(Broadcast)')
   endif

   else ! (not the owner):
     if (sync_between_timers) then
       call task_sync_filter('SYNC:Owned(Broadcast)')
     endif
     call t_startf('ASSIMILATE:NotOwned(Broadcast)')
     if (packed_sends) then
       call broadcast_recv_chunk_packed_opt(map_pe_to_task(ens_handle, chunks(i)%owner), chunk_data, ens_size, num_groups)
     else
       call broadcast_recv_chunk(map_pe_to_task(ens_handle, chunks(i)%owner), chunk_data)
     endif
     call t_stopf('ASSIMILATE:NotOwned(Broadcast)')
     if (sync_between_timers) then
       call task_sync_filter('SYNC:NotOwned(Broadcast)')
     endif
     call t_startf('ASSIMILATE:NotOwned(Compute)')
     call t_stopf('ASSIMILATE:NotOwned(Compute)')
  endif

  if (sync_between_timers) then
    call task_sync_filter('SYNC:NotOwned(Compute)')
  endif

  call t_startf('ASSIMILATE:QC_CHECK')
  !QC_CHECK: do j = 1, chunk_data%num_obs
  QC_CHECK: do j = 1, chunk_data%comm_obs
     if (nint(chunk_data%obs_qc(j)) /= 0) then
        qcd = qcd + 1
        !write(*,*) "DEBUG: QC_CHECK /= 0", my_task_id(), j, chunk_data%num_obs
        !!!! ! This is a hack - we're going to swap the current value with the last
        !!!! ! value, then decrement the count, effectively removing this one.  If
        !!!! ! we're at the last one, we cycle to the next chunk:
        if (j == chunk_data%num_obs) then
           chunk_data%num_obs = chunk_data%num_obs - 1
        else
           ! Can't just swap with last one since last might be bad; so we have
           ! to search backwards:
           do k = chunk_data%num_obs, j+1, -1
             if (nint(chunk_data%obs_qc(k)) == 0) then ! Valid QC, so swap with this ob
              chunk_data%obs_prior(:,j) = chunk_data%obs_prior(:,k)
              chunk_data%obs_inc(:,j) = chunk_data%obs_inc(:,k)
              chunk_data%net_a(:,j) = chunk_data%net_a(:,k)
              chunk_data%obs_qc(j) = chunk_data%obs_qc(k)
              chunk_data%vertvalue_obs_in_localization_coord(j) = chunk_data%vertvalue_obs_in_localization_coord(k)
              chunk_data%whichvert_real(j) = chunk_data%whichvert_real(k)
              ! Also change the chunks(i)%obs_list, since that'll be used for
              ! indexing later -- maybe this should be done with a logical var
              ! instead?  Eg, 'process', and skip false ones?
              chunks(i)%obs_list(j) = chunks(i)%obs_list(k)

              ! We now have a max possible 'k - 1' obs in this chunk, with
              ! potentially fewer if others are bad:
              chunk_data%num_obs = k - 1
            endif
          enddo 


!           chunk_data%obs_prior(j,:) = chunk_data%obs_prior(chunk_data%num_obs,:)
!           chunk_data%obs_inc(j,:) = chunk_data%obs_inc(chunk_data%num_obs,:)
!           chunk_data%net_a(j,:) = chunk_data%net_a(chunk_data%num_obs,:)
!           chunk_data%obs_qc(j) = chunk_data%obs_qc(chunk_data%num_obs)
!           chunk_data%vertvalue_obs_in_localization_coord(j) = chunk_data%vertvalue_obs_in_localization_coord(chunk_data%num_obs)
!           chunk_data%whichvert_real(j) = chunk_data%whichvert_real(chunk_data%num_obs)
!           ! Also change the chunks(i)%obs_list, since that'll be used for
!           ! indexing later -- maybe this should be done with a logical var
!           ! instead?  Eg, 'process', and skip false ones?
!           chunks(i)%obs_list(j) = chunks(i)%obs_list(chunk_data%num_obs)
!
!           ! Decrement the number of obs in this chunk
!           chunk_data%num_obs = chunk_data%num_obs - 1
!           !j = j -1

           !write(*,*) "QC_CHECK fail on ", i, j
           cycle QC_CHECK
       endif
       if (j == 0) then
         !cycle CHUNK_LOOP
       endif
    endif
  enddo QC_CHECK
  call t_stopf('ASSIMILATE:QC_CHECK')

  if (sync_between_timers) then
       call task_sync_filter('SYNC:QC_Check')
  endif

  !write(*,*) "Debug: chunk_data%comm_obs = ", chunk_data%comm_obs,  OMP_GET_NUM_THREADS()

  !write(*,*) "DEBUG: Num_groups = ", num_groups, chunk_data%num_obs
  !do j = 1, chunk_data%num_obs
  !$OMP  PARALLEL DO schedule(runtime) default(none) &
  !$OMP& shared(chunk_data, num_groups, grp_beg, grp_end, grp_size, sync_between_timers, obs_seq, keys, chunks, i, close_obs_caching, ens_handle, cutoff, allow_missing_in_clm, ens_size, local_varying_ss_inflate, adjust_obs_impact, ENS_INF_COPY, ENS_INF_SD_COPY) &
  !$OMP& shared(obs_ens_handle, inflate_only, obs_impact_table, my_obs_indx, gc_obs, my_obs_loc, my_obs_kind, my_obs_type, gc_state, my_state_loc, my_state_kind, my_state_indx) &
  !$OMP& private(grp_bot, grp_top, obs_prior_mean, obs_prior_var, observation, obs_def, base_obs_loc, obs_err_var, base_obs_type, base_obs_kind, dummyloc, base, num_close_obs, close_obs_ind, close_obs_dist, elapsed) &
  !$OMP& private(last_base_obs_loc, last_num_close_obs, last_close_obs_ind, last_close_obs_dist, num_close_obs_cached, num_close_obs_calls_made, num_close_states, close_state_ind, close_state_dist) &
  !$OMP& private(last_base_states_loc, last_num_close_states, last_close_state_ind, num_close_states_cached, num_close_states_calls_made, cutoff_orig, last_close_state_dist, cutoff_list, cutoff_rev, state_index, missing_in_state, skipped_missing) &
  !$OMP& private(skipped_covfactor, varying_ss_inflate, varying_ss_inflate_sd, reg_factor, obs_index, cov_factor, impact_factor, increment, reg_coef, obs_time) &
  !$OMP& private(mythread)
  do j = 1, chunk_data%comm_obs
    call t_startf('ASSIMILATE:ComputePriors')
   ! Can compute prior mean and variance of obs for each group just once here
    do group = 1, num_groups
      grp_bot = grp_beg(group)
      grp_top = grp_end(group)
!      write(*,*) "DEBUG : obs_prior_sum(2) = ", sum(chunk_data%obs_prior(j,grp_bot:grp_top)), get_ob_id(chunks, i, j)
      obs_prior_mean(group) = sum(chunk_data%obs_prior(grp_bot:grp_top,j)) / grp_size
      obs_prior_var(group) = sum((chunk_data%obs_prior(grp_bot:grp_top,j) - obs_prior_mean(group))**2) / &
         (grp_size - 1)
      if (obs_prior_var(group) < 0.0_r8) obs_prior_var(group) = 0.0_r8
      !write(*,*) "DEBUG : obs_prior_mean = ", obs_prior_mean(group), chunks(i)%obs_list(j)
    end do
!    write(*,*) "DEBUG: Priors = ", get_ob_id(chunks, i, j), sum(obs_prior_mean), sum(obs_prior_var)


   call t_stopf('ASSIMILATE:ComputePriors')
   if (sync_between_timers) then
      call task_sync_filter('SYNC:ComputePriors')
   endif
   !call task_sync()
   ! -------------- NOTE: Skipping all adaptive localization stuff for now ---------
   ! ------- NOTE: Turns out, get_close_state was in the            ----
   ! -------       adaptivelocalization section .. we need to do it ----


   ! Do we really need to do get_close_states in the coloring mode?  We already
   ! know the close states!  Something to think about.  Even if storing all
   ! the info is too memory intensive, maybe storing a subgrid of 8 cells would
   ! help?  Measure this to see how long it takes, then decide.


    call t_startf('ASSIMILATE:AdaptiveLocalization')
   ! Every pe has information about the global obs sequence
   !if (chunks(i)%obs_list(j) > 192895) then
   !    write(*,*) "Trace: ", i, j
   ! endif
   !! OpenMP issue - race condition?  bpd6
   !write(*,*) "Debug-A: LOC(observation) : ", mythread, loc(observation), observation%key
   !call get_obs_from_key(obs_seq, keys(chunks(i)%obs_list(j)), observation)
   observation = obs_seq%obs(keys(chunks(i)%obs_list(j)))
    mythread =  OMP_GET_THREAD_NUM()
    !call sleep(5)
    !write(*,'(A,I4,I9,I9,I4,I4)') "Debug2: chunk_data%comm_obs = ", mythread, j, observation%key, chunk_data%comm_obs, OMP_GET_NUM_THREADS()
   !write(*,*) "Debug-C: LOC(observation) : ", mythread, loc(observation), observation%key
   !!  $OMP BARRIER
   !write(*,*) "Debug-D: LOC(observation) : ", mythread, loc(observation), observation%key
   !! $OMP BARRIER
   call get_obs_def(observation, obs_def)
   !write(*,*) "Debug-ObsDef : ", mythread, obs_def%location%lon, obs_def%location%lat

   base_obs_loc = get_obs_def_location(obs_def)
   obs_err_var = get_obs_def_error_variance(obs_def)
   base_obs_type = get_obs_def_type_of_obs(obs_def)
   if (base_obs_type > 0) then
     base_obs_kind = get_quantity_for_type_of_obs(base_obs_type)
   else
     call get_state_meta_data(-1*int(base_obs_type,i8),dummyloc, base_obs_kind)  ! identity obs
   endif

   if (.not. close_obs_caching) then
      if (timing) call start_mpi_timer(base)
      call get_close_obs(gc_obs, base_obs_loc, base_obs_type, &
                         my_obs_loc, my_obs_kind, my_obs_type, &
                         num_close_obs, close_obs_ind, close_obs_dist, ens_handle)
      if (timing) then
         elapsed = read_mpi_timer(base)
         print*, 'get_close_obs1 time :', elapsed, 'rank ', my_task_id()
      endif

   else
 
      if (base_obs_loc == last_base_obs_loc) then
         num_close_obs     = last_num_close_obs
         close_obs_ind(:)  = last_close_obs_ind(:)
         close_obs_dist(:) = last_close_obs_dist(:)
         num_close_obs_cached = num_close_obs_cached + 1
      else
         if (timing .and. i < 100) call start_mpi_timer(base)
         !write(*,*) "Entering get_close_obs : ", chunks(i)%obs_list(j), base_obs_loc%lon, base_obs_loc%lat
         call get_close_obs(gc_obs, base_obs_loc, base_obs_type, &
                            my_obs_loc, my_obs_kind, my_obs_type, &
                            num_close_obs, close_obs_ind, close_obs_dist, ens_handle)
         if (timing .and. i < 100) then
            elapsed = read_mpi_timer(base)
            print*, 'get_close_obs2 time :', elapsed, 'rank ', my_task_id()
         endif

         last_base_obs_loc      = base_obs_loc
         last_num_close_obs     = num_close_obs
         last_close_obs_ind(:)  = close_obs_ind(:)
         last_close_obs_dist(:) = close_obs_dist(:)
         num_close_obs_calls_made = num_close_obs_calls_made +1
      endif
   endif
   if (close_obs_caching) then
     !write(*,*) "CloseObs : CACHING is TRUE", num_close_obs  !, close_obs_dist
   else 
     !write(*,*) "CloseObs : CACHING is FALSE", num_close_obs  !, close_obs_dist
   endif

   ! Debug for obs distance:
   !write(*,*) "DEBUG Close Distance: ", num_close_obs
   !do debug_loop = 1, num_close_obs
   !   write(*,*) "DCD : ", close_obs_dist(close_obs_ind(debug_loop))
   !enddo


! Checking close obs error, disabling states for now - fix this later!
! num_close_states = 0

   !!  !$OMP BARRIER
    !write(*,'(A,I4,I8,I8,G14.8,G14.8,G14.8,I8)') "Debug3: base_obs_loc  = ", mythread, j, observation%key, base_obs_loc%lon, base_obs_loc%lat, base_obs_loc%vloc, base_obs_loc%which_vert
   if (.not. close_obs_caching) then
      call get_close_state(gc_state, base_obs_loc, base_obs_type, &
                           my_state_loc, my_state_kind, my_state_indx, &
                           num_close_states, close_state_ind, close_state_dist, ens_handle)
      if (timing .and. i < 100) then
         elapsed = read_mpi_timer(base)
         print*, 'get_close_state1 time :', elapsed, 'rank ', my_task_id()
      endif
   else
      if (base_obs_loc == last_base_states_loc) then
         num_close_states    = last_num_close_states
         close_state_ind(:)  = last_close_state_ind(:)
         close_state_dist(:) = last_close_state_dist(:)
         num_close_states_cached = num_close_states_cached + 1
     else
         if (timing .and. i < 100) call start_mpi_timer(base)
         call get_close_state(gc_state, base_obs_loc, base_obs_type, &
                              my_state_loc, my_state_kind, my_state_indx, &
                              num_close_states, close_state_ind, close_state_dist, ens_handle)
         if (timing .and. i < 100) then
            elapsed = read_mpi_timer(base)
            print*, 'get_close_state2 time :', elapsed, 'rank ', my_task_id()
         endif

         last_base_states_loc     = base_obs_loc
         last_num_close_states    = num_close_states
         last_close_state_ind(:)  = close_state_ind(:)
         last_close_state_dist(:) = close_state_dist(:)
         num_close_states_calls_made = num_close_states_calls_made + 1
      endif
   endif

!  num_close_states = 0

   if (base_obs_type > 0) then
      cutoff_orig = cutoff_list(base_obs_type)
   else
      cutoff_orig = cutoff
   endif
  cutoff_rev = cutoff_orig

   !checksum = sum(obs_ens_handle%copies(1:ens_size,:))
   !call MPI_Reduce(num_close_states, num_close_states_total, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
   !call MPI_Reduce(num_close_obs,    num_close_obs_total,    1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
   !call MPI_Reduce(checksum, checksum_total, 1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, iError)

   !if (my_task_id() == 0) then
   ! write(*,'(A,I,I,A,F,I)') "DEBUG: Close States / Obs : ", num_close_states_total, num_close_obs_total, "     ", checksum_total, chunks(i)%obs_list(j)
   !endif

   !num_close_states = 0

   call t_stopf('ASSIMILATE:AdaptiveLocalization')

! bpd6 - error checking:
!do iError = 1, obs_ens_handle%my_num_vars
!  write(*,*) "ECheck5 : ", iError, sum(obs_ens_handle%copies(1:3,iError))
!end do

!do iError = 1, chunk_data%num_obs
!  write(*,*) "ECheck5b: ", iError, sum(chunk_data%obs_prior(iError,:))
!end do

!call MPI_Reduce(num_close_states, num_close_states_total, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!call MPI_Reduce(checksum, checksum_total, 1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!if (my_task_id() == 0) then
!   write(*,*) "PreCheck2: ", checksum_total, num_close_states_total
!endif

!write(*,*) "CHECKSUM2a : " , sum(chunk_data%obs_prior)
!if (get_ob_id(chunks, i, j) == 5) then
! if (task_count() == 1) then
!   !write(*,*) "ObID5 : ", sum(chunk_data%obs_prior(3,1:3)), sum(obs_ens_handle%copies(3,1:3))
!   write(*,*) "ObID5 : ", sum(chunk_data%obs_prior(3,1:3)), sum(obs_ens_handle%copies(3,1:3))
! else if (my_task_id() == 0) then
!   write(*,*) "ObID5 : ", sum(chunk_data%obs_prior(2,1:3)), sum(obs_ens_handle%copies(2,1:3))
!   write(*,*) "ObID5 : ", sum(chunk_data%obs_prior(2,1:3)), sum(obs_ens_handle%copies(2,1:3))
! endif
 !write(*,*) "ObID5 : ", sum(chunk_data%obs_prior(5,:)), sum(obs_ens_handle%copies(5:,:))
!endif

  if (sync_between_timers) then
     call task_sync_filter('SYNC:AdaptiveLocalization')
  endif

   call t_startf('ASSIMILATE:UpdateState')

  !write(*,*) "DEBUG : num_close_states = ", num_close_states, chunks(i)%obs_list(j)
  !write(*,*) "close_state_dist(1) = ", close_state_dist(1), chunks(i)%obs_list(j)
  !write(*,*) "cutoff_rev = ", cutoff_rev, chunks(i)%obs_list(j)
  !write(*,*) "my_state_loc(1) = ", my_state_loc(close_state_ind(1))%lon, chunks(i)%obs_list(j)

  !testval = 0.0
  !testval2 = 0.0
  ! debug values:
  !stateindex_sum = 0
  !regfactor_sum = 0.0D0
  !increment_sum = 0.0D0
  !write(*,*) "StateUpdate0 : ", size(close_state_ind), sum(close_state_ind)
   !! !$OMP BARRIER
    !write(*,'(A,I,I,I,G,G,G,I)') "Debug4: base_obs_loc  = ", mythread, j, observation%key, base_obs_loc%lon, base_obs_loc%lat, base_obs_loc%vloc, base_obs_loc%which_vert
    !write(*,'(A,I4,I8,I8)') "Debug4: --------------- ", mythread, j, observation%key
   STATE_UPDATE: do k = 1, num_close_states
      state_index = close_state_ind(k)
      !write(my_task_id()+15,'(A,I,I,I,I,I)') "SU_TraceA : ", get_ob_id(chunks, i, j), i, j, ens_handle%my_vars(state_index), state_index

      if ( allow_missing_in_clm ) then
         ! Some models can take evasive action if one or more of the ensembles have
         ! a missing value. Generally means 'do nothing' (as opposed to DIE)
         missing_in_state = any(ens_handle%copies(1:ens_size, state_index) == MISSING_R8)
         if ( missing_in_state ) then
           skipped_missing = skipped_missing + 1
           cycle STATE_UPDATE
         endif
      endif

      !write(my_task_id()+15,*) "SU_TraceB : ", get_ob_id(chunks, i, j), ens_handle%my_vars(state_index)

      ! Get the initial values of inflation for this variable if state varying inflation
      if(local_varying_ss_inflate) then
         varying_ss_inflate    = ens_handle%copies(ENS_INF_COPY,    state_index)
         varying_ss_inflate_sd = ens_handle%copies(ENS_INF_SD_COPY, state_index)
      else
         varying_ss_inflate    = 0.0_r8
         varying_ss_inflate_sd = 0.0_r8
      endif
     
      ! Compute the distance and covariance factor 
!      cov_factor = comp_cov_factor(close_state_dist(k), cutoff_rev, &
!         base_obs_loc, base_obs_type, my_state_loc(state_index), my_state_kind(state_index))
!bpd6 - debug
cov_factor = 0.01
      !testval = testval + cov_factor !debug
      
      ! if external impact factors supplied, factor them in here
      ! FIXME: this would execute faster for 0.0 impact factors if
      ! we check for that before calling comp_cov_factor.  but it makes
      ! the logic more complicated - this is simpler if we do it after.
      if (adjust_obs_impact) then
         impact_factor = obs_impact_table(base_obs_type, my_state_kind(state_index))
         cov_factor = cov_factor * impact_factor
      endif

      ! If no weight is indicated, no more to do with this state variable
      if(cov_factor <= 0.0_r8) then
          skipped_covfactor = skipped_covfactor + 1
          cycle STATE_UPDATE
      endif

      !write(my_task_id()+15,*) "SU_TraceC : ", get_ob_id(chunks, i, j), ens_handle%my_vars(state_index)
      increment = 0
      !write(my_task_id()+15,'(A,I,I,G,G,G)') "SU_TraceC : ", get_ob_id(chunks, i, j), ens_handle%my_vars(state_index), sum(increment), sum(obs_prior_mean), sum(obs_prior_var)

      ! Loop through groups to update the state variable ensemble members
      do group = 1, num_groups
         grp_bot = grp_beg(group)
         grp_top = grp_end(group)
         ! Do update of state, correl only needed for varying ss inflate
!!         if(local_varying_ss_inflate .and. varying_ss_inflate > 0.0_r8 .and. &
!!           varying_ss_inflate_sd > 0.0_r8) then
!!           call update_from_obs_inc(obs_prior(grp_bot:grp_top), obs_prior_mean(group), &
!!               obs_prior_var(group), obs_inc(grp_bot:grp_top), &
!!               ens_handle%copies(grp_bot:grp_top, state_index), grp_size, &
!!               increment(grp_bot:grp_top), reg_coef(group), net_a(group), correl(group))
!!         else
            call update_from_obs_inc(chunk_data%obs_prior(grp_bot:grp_top,j), obs_prior_mean(group), &
               obs_prior_var(group), chunk_data%obs_inc(grp_bot:grp_top,j), &
               ens_handle%copies(grp_bot:grp_top, state_index), grp_size, &
               increment(grp_bot:grp_top), reg_coef(group), chunk_data%net_a(group,j))
           !write(*,*) "Inc: ", increment(1)
!!         endif
      end do
      !testval2 = testval2 + increment(1)
      !write(my_task_id()+15,'(A,I,I,G,G,G)') "SU_TraceD : ", get_ob_id(chunks, i, j), ens_handle%my_vars(state_index), sum(increment), sum(obs_prior_mean), sum(obs_prior_var)


      ! Compute an information factor for impact of this observation on this state
      if(num_groups == 1) then
          reg_factor = 1.0_r8
      else
         ! Pass the time along with the index for possible diagnostic output
         ! Compute regression factor for this obs-state pair
         reg_factor = comp_reg_factor(num_groups, reg_coef, obs_time, i, my_state_indx(state_index))
      endif

      ! The final factor is the minimum of group regression factor and localization cov_factor
      reg_factor = min(reg_factor, cov_factor)
      !write(*,*) "Reg factor : ", reg_factor
      !increment = 1.0_r8
      !write(*,*) "Increment: ", increment(1:2)

!PAR NEED TO TURN STUFF OFF MORE EFFICEINTLY
      ! If doing full assimilation, update the state variable ensemble with weighted increments
      if(.not. inflate_only) then
         ens_handle%copies(1:ens_size, state_index) = &
            ens_handle%copies(1:ens_size, state_index) + reg_factor * increment
      endif


      !stateindex_sum = stateindex_sum + ens_handle%my_vars(state_index)
      !regfactor_sum = regfactor_sum + reg_factor
      !increment_sum = increment_sum + SUM(increment)


      ! Compute spatially-varying state space inflation
      if(local_varying_ss_inflate) then
!!         ! base is the initial inflate value for this state variable
!!         ss_inflate_base = ens_handle%copies(ENS_SD_COPY, state_index)
!!         ! Loop through each group to update inflation estimate
!!         GroupInflate: do group = 1, num_groups
!!            if(varying_ss_inflate > 0.0_r8 .and. varying_ss_inflate_sd > 0.0_r8) then
!!               ! Gamma is less than 1 for varying ss, see adaptive inflate module
!!               gamma = reg_factor * abs(correl(group))
!!               ! Deflate the inflated variance using the INITIAL state inflate
!!               ! value (before these obs started gumming it up).
!!               ens_obs_mean = orig_obs_prior_mean(group)
!!               ens_obs_var =  orig_obs_prior_var(group)
!!
!!               ! Remove the impact of inflation to allow efficient single pass with assim.
!!               if ( abs(gamma) > small ) then
!!                  ens_var_deflate = ens_obs_var / &
!!                     (1.0_r8 + gamma*(sqrt(ss_inflate_base) - 1.0_r8))**2
!!               else
!!                  ens_var_deflate = ens_obs_var
!!               endif
!!                  
!!               ! If this is inflate only (i.e. posterior) remove impact of this obs.
!!               if(inflate_only .and. &
!!                     ens_var_deflate               > small .and. &
!!                     obs_err_var                   > small .and. & 
!!                     obs_err_var - ens_var_deflate > small ) then 
!!                  r_var  = 1.0_r8 / (1.0_r8 / ens_var_deflate - 1.0_r8 / obs_err_var)
!!                  r_mean = r_var *(ens_obs_mean / ens_var_deflate - obs(1) / obs_err_var)
!!               else
!!                  r_var = ens_var_deflate
!!                  r_mean = ens_obs_mean
!!               endif
!!
!!               ! IS A TABLE LOOKUP POSSIBLE TO ACCELERATE THIS?K
!!               ! Update the inflation values
!!               call update_inflation(inflate, varying_ss_inflate, varying_ss_inflate_sd, &
!!                  r_mean, r_var, obs(1), obs_err_var, gamma)
!!            else
!!               ! if we don't go into the previous if block, make sure these
!!               ! have good values going out for the block below
!!               r_mean = orig_obs_prior_mean(group)
!!               r_var =  orig_obs_prior_var(group)
!!            endif
!!
!!            ! Update adaptive values if posterior outlier_ratio test doesn't fail.
!!            ! Match code in obs_space_diags() in filter.f90
!!            do_adapt_inf_update = .true.
!!            if (inflate_only) then
!!               diff_sd = sqrt(obs_err_var + r_var) 
!!               if (diff_sd > 0.0_r8) then
!!                  outlier_ratio = abs(obs(1) - r_mean) / diff_sd
!!                  do_adapt_inf_update = (outlier_ratio <= 3.0_r8) 
!!               endif
!!            endif
!!            if (do_adapt_inf_update) then   
!!               ens_handle%copies(ENS_INF_COPY, state_index) = varying_ss_inflate
!!               ens_handle%copies(ENS_INF_SD_COPY, state_index) = varying_ss_inflate_sd
!!            endif
!!         end do GroupInflate
      endif

   end do STATE_UPDATE

!checksum = sum(obs_ens_handle%copies(1:ens_size,:))
!call MPI_Reduce(num_close_obs, num_close_obs_total, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!call MPI_Reduce(checksum, checksum_total, 1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!if (my_task_id() == 0) then
!!   write(*,*) "PreCheck3: ", checksum_total, num_close_obs_total
!endif

!   call MPI_Reduce(stateindex_sum, stateindex_total, 1, MPI_INTEGER8, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!   call MPI_Reduce(regfactor_sum, regfactor_total,   1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!   call MPI_Reduce(increment_sum, increment_total,   1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!
!   call MPI_Reduce(skipped_missing, skipped_missing_total, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!   call MPI_Reduce(skipped_covfactor, skipped_covfactor_total, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
!write(*,*) "CHECKSUM3a : " , sum(chunk_data%obs_prior)

    !write(*,*) "StateUpdate_SI = ", stateindex_sum

!   if (my_task_id() == 0) then
      !write(*,*) "DEBUG: StateUpdate2 = ", skipped_missing_total, skipped_covfactor_total
      !write(*,*) "DEBUG: StateUpdateA = ", stateindex_total
      !write(*,*) "DEBUG: StateUpdateB = ", regfactor_total
      !write(*,*) "DEBUG: StateUpdateC = ", increment_total
!  endif 

   !write(*,*) "DEBUG : cov_factor sum = ", testval, chunks(i)%obs_list(j)
   !write(*,*) "DEBUG : sum_increment = ", testval2, chunks(i)%obs_list(j)
!!   if (timing .and. i < 1000) then
!!      elapsed = read_mpi_timer(base)
!!      print*, 'state_update time :', elapsed, 'rank ', my_task_id()
!!   endif
!!
!! ! stop the timer for this section for this rank:
!!  call system_clock(count=timer_count2)
!!  !write(*,*) "Debug: ", timer_count, timer_count2, timer_count2-timer_count
!!  stateupdate_time = DBLE(timer_count2 - timer_count) / DBLE(timer_rate)
!!!  write(*,*) "Debug: ", stateupdate_time
!!
!!   !bpd6 - 2018-01-16 mod
!!   !call write_obdata(obdata_unit, i, num_close_states, skipped_missing, skipped_covfactor, stateupdate_time)
!!
   call t_stopf('ASSIMILATE:UpdateState')

   if (sync_between_timers) then
      call task_sync_filter('SYNC:UpdateState')
   endif

   !write(*,*) "DEBUG: num_close_obs = ", num_close_obs


!!   call t_startf('ASSIMILATE:UpdateObs')
!!   !call test_state_copies(ens_handle, 'after_state_updates')
!!
!!   !------------------------------------------------------
!!
!!    !bpd6- new obdata update
!!    call write_obdata2(obdata_unit2, i)
!!
!!   ! Now everybody updates their obs priors (only ones after this one)
!!   if (timing .and. i < 1000) call start_mpi_timer(base)
!num_close_obs = 0 !! ERROR - put here to fix some issue in the OBS_UPDATE loop
                  !! that's giving incorrect answers in parallel /graph mode
                  !! .. And we shouldn't have any dependent obs anyway.

   call t_startf('ASSIMILATE:UpdateObs')

   OBS_UPDATE: do k = 1, num_close_obs
      obs_index = close_obs_ind(k)

      ! Only have to update obs that have not yet been used
      if(my_obs_indx(obs_index) > chunks(i)%obs_list(j)) then

         ! If the forward observation operator failed, no need to 
         ! update the unassimilated observations 
         if (any(obs_ens_handle%copies(1:ens_size, obs_index) == MISSING_R8)) cycle OBS_UPDATE

         ! Compute the distance and the covar_factor
         !cov_factor = comp_cov_factor(close_obs_dist(k), cutoff_rev, base_obs_loc, base_obs_type, my_obs_loc(obs_index), my_obs_kind(obs_index))
         cov_factor = 0.01

         ! if external impact factors supplied, factor them in here
         ! FIXME: this would execute faster for 0.0 impact factors if
         ! we check for that before calling comp_cov_factor.  but it makes
         ! the logic more complicated - this is simpler if we do it after.
         if (adjust_obs_impact) then
            impact_factor = obs_impact_table(base_obs_type, my_obs_kind(obs_index))
            cov_factor = cov_factor * impact_factor
         endif

         if(cov_factor <= 0.0_r8) cycle OBS_UPDATE

        ! bpd6 - NOW, finally, we have an ob we're actually updating.. append to
        ! our obdata file:
        !write(*,*) "BRIAN: ", my_obs_indx(obs_index), obs_index, i
!        call append_obdata2(obdata_unit2, obs_index)


         ! Loop through and update ensemble members in each group
         do group = 1, num_groups
            grp_bot = grp_beg(group)
            grp_top = grp_end(group)
            call update_from_obs_inc(chunk_data%obs_prior(grp_bot:grp_top,j), obs_prior_mean(group), &
               obs_prior_var(group), chunk_data%obs_inc(grp_bot:grp_top,j), &
                obs_ens_handle%copies(grp_bot:grp_top, obs_index), grp_size, &
                increment(grp_bot:grp_top), reg_coef(group), chunk_data%net_a(group,j))
         end do

         ! FIXME: could we move the if test for inflate only to here?

         ! Compute an information factor for impact of this observation on this state
         if(num_groups == 1) then
             reg_factor = 1.0_r8
         else
            ! Pass the time along with the index for possible diagnostic output
            ! Compute regression factor for this obs-state pair
            ! Negative indicates that this is an observation index
            reg_factor = comp_reg_factor(num_groups, reg_coef, obs_time, i, -1*my_obs_indx(obs_index))
         endif

         ! Final weight is min of group and localization factors
         reg_factor = min(reg_factor, cov_factor)

         ! Only update state if indicated (otherwise just getting inflation)
         if(.not. inflate_only) then
            obs_ens_handle%copies(1:ens_size, obs_index) = &
              obs_ens_handle%copies(1:ens_size, obs_index) + reg_factor * increment
         endif
      endif
      !write(*,*) "Obs Update Checksum : ", sum(chunk_data%obs_prior(j,:)), my_obs_indx(obs_index), chunks(i)%obs_list(j)
   end do OBS_UPDATE
   call t_stopf('ASSIMILATE:UpdateObs')

   if (sync_between_timers) then
      call task_sync_filter('SYNC:UpdateObs') !-- filter3
    endif

!!   if (timing .and. i < 1000) then
!!      elapsed = read_mpi_timer(base)
!!      print*, 'obs_update time :', elapsed, 'rank ', my_task_id()
!!   endif
!!
!!   !call test_state_copies(ens_handle, 'after_obs_updates')
!!
!!
!!   if (my_task_id() == 0 .and. timing) then
!!      elapse_array(i) = read_mpi_timer(base2)
!!      if (timing1) print*, 'outer sequential obs time :', elapsed, ' obs ', i, ' rank ', my_task_id()
!!   endif
!!
!!   call t_stopf('ASSIMILATE:UpdateObs')
!!   call task_sync()
!!
  enddo ! Obs loop - shouldn't be here, but this is for testing
!!  !write(*,*) "CHECKSUM --------------------- "
!!  call sleep(1)
end do CHUNK_LOOP

!call MPI_Finalize(iError)
!stop

! Temporary
!call MPI_Finalize(iError)
!write(*,*) "Exiting.."
!stop

!write(*,*) "QC'd obs: ", qcd
if (sync_between_timers) then
  call task_sync_final()
endif

call t_stopf('Full Loop')
call task_sync()
call t_startf('ASSIMILATE:Post.Loop')


! Every pe needs to get the current my_inflate and my_inflate_sd back
if(local_single_ss_inflate) then
   ens_handle%copies(ENS_INF_COPY, :) = my_inflate
   ens_handle%copies(ENS_INF_SD_COPY, :) = my_inflate_sd
end if

! Free up the storage
call destroy_obs(observation)
call get_close_destroy(gc_state)
call get_close_destroy(gc_obs)

! print some stats about the assimilation
if (my_task_id() == 0 .and. timing) then
   write(msgstring, *) 'average assim time: ', sum(elapse_array) / size(elapse_array)
   call error_handler(E_MSG,'filter_assim:',msgstring)

   write(msgstring, *) 'minimum assim time: ', minval(elapse_array)
   call error_handler(E_MSG,'filter_assim:',msgstring)

   write(msgstring, *) 'maximum assim time: ', maxval(elapse_array)
   call error_handler(E_MSG,'filter_assim:',msgstring)
endif

if (my_task_id() == 0 .and. timing) deallocate(elapse_array)

! Assure user we have done something
write(msgstring, '(A,I8,A)') &
   'Processed', obs_ens_handle%num_vars, ' total observations'
if (print_trace_details >= 0) call error_handler(E_MSG,'filter_assim:',msgstring)

! diagnostics for stats on saving calls by remembering obs at the same location.
! change .true. to .false. in the line below to remove the output completely.
if (close_obs_caching) then
   if (num_close_obs_cached > 0 .and. do_output()) then
      print *, "Total number of calls made    to get_close_obs for obs/states:    ", &
                num_close_obs_calls_made + num_close_states_calls_made
      print *, "Total number of calls avoided to get_close_obs for obs/states:    ", &
                num_close_obs_cached + num_close_states_cached
      if (num_close_obs_cached+num_close_obs_calls_made+ &
          num_close_states_cached+num_close_states_calls_made > 0) then 
         print *, "Percent saved: ", 100.0_r8 * &
                   (real(num_close_obs_cached+num_close_states_cached, r8) /  &
                   (num_close_obs_calls_made+num_close_obs_cached +           &
                    num_close_states_calls_made+num_close_states_cached))
      endif
   endif
endif

!call test_state_copies(ens_handle, 'end')

!GSR close the localization diagnostics file
if(output_localization_diagnostics .and. my_task_id() == 0) then
  call close_file(localization_unit)
end if

if (my_task_id() == 0) then
  call close_file(histogram_unit) ! bpd6
endif

! get rid of mpi window
call free_mean_window()

call task_sync()
call t_stopf('ASSIMILATE:Post.Loop')

end subroutine filter_assim

function graph_owners_index(chunks, current_chunk, ob_in_chunk)
  type(chunk_type), dimension(*), intent(in) :: chunks
  integer, intent(in) :: current_chunk
  integer, intent(in) :: ob_in_chunk
  integer  :: graph_owners_index

  integer :: i
  integer :: tally

  integer :: pe


  pe = my_task_id()

  tally = 0
  do i = 1, current_chunk-1
    if (pe == chunks(i)%owner) then
      tally = tally + chunks(i)%num_obs
    endif
  end do

  tally = tally + ob_in_chunk


  graph_owners_index = tally
end function graph_owners_index


function graph_owner_index(current_chunk, ob_in_chunk, chunk_size, index_map)
  integer, intent(in) :: current_chunk
  integer, intent(in) :: ob_in_chunk
  integer, intent(in) :: chunk_size
  integer, intent(in), dimension(*) :: index_map
  integer  :: graph_owner_index

  integer :: pos

  pos = (current_chunk * chunk_size) + ob_in_chunk
  graph_owner_index = index_map(pos)
end function graph_owner_index


!subroutine build_graph_owners_index(chunks, current_chunk, ob_in_chunk)
subroutine build_graph_owners_index(chunks, chunk_size, graph_owner_index_array)
  type(chunk_type), dimension(:), intent(in) :: chunks
  integer, intent(in) :: chunk_size
  integer, intent(out), dimension(:), allocatable :: graph_owner_index_array

  integer :: index_size
  integer :: pe
  integer :: tally
  integer :: i, j

  index_size = size(chunks) * chunk_size
  allocate(graph_owner_index_array(index_size))

  graph_owner_index_array = 0
  pe = my_task_id()

  tally = 0
  do i = 1, size(chunks)
    if (pe == chunks(i)%owner) then

      !graph_owner_index_array((i * chunk_size))
    endif
  end do

  !tally = tally + ob_in_chunk


  !graph_owner_index_array = tally
end subroutine build_graph_owners_index


function get_ob_id(chunks, i, j)
  type(chunk_type), dimension(*), intent(in) :: chunks
  integer, intent(in) :: i, j

  integer :: get_ob_id

  integer :: z, tally, pe

  tally = 0
  do z = 1, i-1
    tally = tally + chunks(i)%num_obs
  end do

  tally = tally + j
  get_ob_id = tally
end function get_ob_id

!!-------------------------------------------------------------
!subroutine read_coloring(colors)
!type(coloring_type), intent(out) :: colors
!
!integer :: i
!
!! open the file (default file name for now)
!open(9, file="chunks.dat", status = 'old')
!
!! Get the number of colors, number of chunks (for now) and chunk size(for now):
!read(9,*) colors%num_colors, colors%num_chunks, colors%chunk_size
!
!! Allocate the 'obchunks' array:
!allocate(colors%obchunks(colors%num_chunks, 1+colors%chunk_size))
!
!
!! Get the observations associated with each chunk
!do i = 1, colors%num_chunks
!  read(9,*) colors%obchunks(i,:)
!  !write(*,*) "BRIAN: Got chunk,color of :", i, colors%obchunks(i,1)
!end do
!close(9)
!
!write(*,*) "DEBUG: Got colors / chunks  :", colors%num_colors, colors%num_chunks
!
!end subroutine read_coloring
!-------------------------------------------------------------

!-------------------------------------------------------------
subroutine read_obs_colors(filename, num_obs, colors)
   character(len=*),  intent(in)  :: filename
   integer(kind=8),           intent(in)  :: num_obs
   type(colors_type), intent(out) :: colors

  integer :: colorfile
  integer :: i

  ! Allocate the array
  allocate(colors%obs_color(num_obs))

  ! open the file 
  colorfile = open_file(filename)

  ! Read in the chunk size:
  read(colorfile,*) colors%chunk_size

  ! Read in the colors, looping over all the obs:
  do i = 1, num_obs
    read(colorfile,*) colors%obs_color(i)
  enddo

  ! Calculate the number of colors:
  ! currently assumes that all color values are consecutive
  colors%num_colors = maxval(colors%obs_color)
end subroutine read_obs_colors

!-------------------------------------------------------------

!subroutine assign_chunks(colors, chunk_list)
!  type(colors_type), intent(in) :: colors
!  type(chunk_type), dimension(:), allocatable :: chunk_list
!end subroutine assign_chunks

subroutine create_chunks(colors, chunks)
  type(colors_type), intent(in) :: colors
  type(chunk_type), dimension(:), allocatable, intent(out) :: chunks

  integer :: chunk_count
  integer :: i,j
  integer, dimension(:), allocatable :: color_sizes, chunks_per_color
  integer :: chunk_index = 1
  integer :: ob_index = 0
  integer :: remaining_obs, numRanks

  ! Allocate color_sizes (array of sizes for each color)
  allocate(color_sizes(colors%num_colors))
  allocate(chunks_per_color(colors%num_colors))

  !write(*,*) "Colors -- number of colors & chunk size = ", colors%num_colors, colors%chunk_size

  ! Get the size and # of chunks of each color - this is a bit hackish, maybe ANY can work better?
  do i = 1, colors%num_colors
    color_sizes(i) = sum(colors%obs_color, colors%obs_color==i) / i
    chunks_per_color(i) = (color_sizes(i) + colors%chunk_size - 1) / colors%chunk_size

    !write(*,*) "Color sizes (",i,") ",color_sizes(i)
    !write(*,*) "Color chunks (",i,") ",chunks_per_color(i)
  enddo 
  
  ! Get the total number of chunks:
  chunk_count = sum(chunks_per_color)

  ! allocate the chunks array:
  allocate(chunks(chunk_count))

  ! Assign chunks
  !write(*,*) "Assigning chunks..."
  numRanks = task_count()
  do i = 1, colors%num_colors
    remaining_obs = color_sizes(i)

    do while (remaining_obs > 0)
      if (remaining_obs > colors%chunk_size) then
        chunks(chunk_index)%num_obs = colors%chunk_size
        chunks(chunk_index)%owner = MOD(chunk_index-1, numRanks)

        do j = 1, colors%chunk_size
          chunks(chunk_index)%obs_list(j) = ob_index + j 
        enddo

        remaining_obs = remaining_obs - colors%chunk_size
        chunk_index = chunk_index + 1
        ob_index = ob_index + colors%chunk_size
      else
        chunks(chunk_index)%num_obs = remaining_obs
        chunks(chunk_index)%owner = MOD(chunk_index-1, numRanks)

        do j = 1, remaining_obs
          chunks(chunk_index)%obs_list(j) = ob_index + j
        enddo

        chunk_index = chunk_index + 1
        ob_index = ob_index + remaining_obs
        remaining_obs = 0
      endif
    enddo
  enddo 

  ! Debug:
  !write(*,*) "Total of colors, chunks : ", sum(color_sizes), chunk_count
  !write(*,*) "Colors%chunk_size = ", colors%chunk_size
  
  !do i = 1, size(chunks)
  !  write(*,*) "Chunk Assigment: ",i," -> ",chunks(i)%owner, chunks(i)%num_obs
  !enddo

end subroutine create_chunks


!-------------------------------------------------------------
subroutine initialize_chunk_data(chunk_size, ens_size, num_groups, chunk_data)
  integer, intent(in) :: chunk_size
  integer, intent(in) :: ens_size
  integer, intent(in) :: num_groups
  type(chunk_data_type), intent(out) :: chunk_data

  integer :: buffer_size

  integer :: i

  allocate(chunk_data%obs_prior(ens_size, chunk_size))
  allocate(chunk_data%obs_inc(ens_size, chunk_size))
  allocate(chunk_data%net_a(num_groups, chunk_size))
  allocate(chunk_data%obs_qc(chunk_size))
  allocate(chunk_data%vertvalue_obs_in_localization_coord(chunk_size))
  allocate(chunk_data%whichvert_real(chunk_size))

 !write(*,*) "Size obs_prior : ", size(chunk_data%obs_prior)

  !allocate(chunk_data%base_obs_loc(chunk_size))

  buffer_size = (chunk_size * ens_size * 2) + (chunk_size * num_groups) + (chunk_size * 3) + 1 ! Plus base_obs_loc?
  if (my_task_id() == 0) then
    write(*,*) "Buffer size : ", buffer_size
  endif
  !buffer_size = (chunk_size * ens_size * 2) + (chunk_size * num_groups) + (chunk_size * 3) + 0 ! no num_obs yet ... Plus base_obs_loc?
  allocate(chunk_data%bcast_buffer(buffer_size))

end subroutine initialize_chunk_data


!-------------------------------------------------------------

subroutine broadcast_send_chunk(from, chunk_data)
    use mpi
   integer, intent(in) :: from
   type(chunk_data_type) :: chunk_data

   integer :: start_offset
   integer :: iError

  start_offset = 1

!   chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs_prior)) = reshape(chunk_data%obs_prior, [ size(chunk_data%obs_prior) ])
!   start_offset = start_offset + size(chunk_data%obs_prior)

  !call MPI_Bcast(chunk_data%num_obs, 1, MPI_INTEGER, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%obs_prior, size(chunk_data%obs_prior), MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%obs_inc,   size(chunk_data%obs_inc),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%net_a,   size(chunk_data%net_a),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%obs_qc,   size(chunk_data%obs_qc),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%vertvalue_obs_in_localization_coord,   size(chunk_data%vertvalue_obs_in_localization_coord),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%whichvert_real,   size(chunk_data%whichvert_real),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)

end subroutine broadcast_send_chunk

!-------------------------------------------------------------

subroutine broadcast_send_chunk_packed(from, chunk_data)
    use mpi
   integer, intent(in) :: from
   type(chunk_data_type) :: chunk_data

   integer :: start_offset
   integer :: iError

   integer :: buffer_size
   integer :: i

  if (sync_between_timers) then
     call task_sync()
  endif

  if (detailed_timers) then
     call t_startf('DETAIL:bcast_send_chunk_pack')
  endif

  start_offset = 1 
   buffer_size  = size(chunk_data%bcast_buffer)


   ! obs_prior
   !chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs_prior)) = reshape(chunk_data%obs_prior, [ size(chunk_data%obs_prior) ])
   !start_offset = start_offset + size(chunk_data%obs_prior)

   ! obs_inc
   !chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs_inc)) = reshape(chunk_data%obs_inc, [ size(chunk_data%obs_inc) ])
   !start_offset = start_offset + size(chunk_data%obs_inc)

   ! net_a
   !chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%net_a)) = reshape(chunk_data%net_a, [ size(chunk_data%net_a) ])
   !start_offset = start_offset + size(chunk_data%net_a)

   ! obs_qc
   !chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs_qc)) = reshape(chunk_data%obs_qc, [ size(chunk_data%obs_qc) ])
   !start_offset = start_offset + size(chunk_data%obs_qc)

   ! vertvalue_obs_in_localization_coord
   !chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%vertvalue_obs_in_localization_coord)) = reshape(chunk_data%vertvalue_obs_in_localization_coord, [ size(chunk_data%vertvalue_obs_in_localization_coord) ])
   !start_offset = start_offset + size(chunk_data%vertvalue_obs_in_localization_coord)

   ! whichvert_real
   !chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%whichvert_real)) = reshape(chunk_data%whichvert_real, [ size(chunk_data%whichvert_real) ])
   !start_offset = start_offset + size(chunk_data%whichvert_real)

  ! Num obs:
  chunk_data%bcast_buffer(start_offset) = chunk_data%num_obs
  start_offset = start_offset + 1

  !do i = 1, chunk_data%num_obs
  !   chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs(i)%obs_prior)-1) = chunk_data%obs(i)%obs_prior
  !   start_offset = start_offset + size(chunk_data%obs(i)%obs_prior)
  !   chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs(i)%obs_inc)-1)   = chunk_data%obs(i)%obs_inc
  !   start_offset = start_offset + size(chunk_data%obs(i)%obs_inc)
  !   chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs(i)%net_a)-1)     = chunk_data%obs(i)%net_a
  !   start_offset = start_offset + size(chunk_data%obs(i)%net_a)
  !   !chunk_data%bcast_buffer(start_offset:start_offset+sizeof(chunk_data%obs(i)%qc))   = chunk_data%obs(i)%qc
  !   !start_offset = start_offset + sizeof(chunk_data%obs(i)%qc)
  !   !chunk_data%bcast_buffer(start_offset:start_offset+sizeof(chunk_data%obs(i)%vertvalue_obs_in_localization_coord))     = chunk_data%obs(i)%vertvalue_obs_in_localization_coord
  !   !start_offset = start_offset + sizeof(chunk_data%obs(i)%vertvalue_obs_in_localization_coord)
  !   !chunk_data%bcast_buffer(start_offset:start_offset+sizeof(chunk_data%obs(i)%whichvert_real))     = chunk_data%obs(i)%whichvert_real
  !   !start_offset = start_offset + sizeof(chunk_data%obs(i)%whichvert_real)
  !   chunk_data%bcast_buffer(start_offset) = chunk_data%obs(i)%qc
  !   start_offset = start_offset + 1
  !   chunk_data%bcast_buffer(start_offset) = chunk_data%obs(i)%vertvalue_obs_in_localization_coord
  !   start_offset = start_offset + 1
  !   chunk_data%bcast_buffer(start_offset) = chunk_data%obs(i)%whichvert_real
  !   start_offset = start_offset + 1
  !end do

  if (detailed_timers) then
     call t_stopf('DETAIL:bcast_send_chunk_pack')
  endif

!   buffer_size = (chunk_size * ens_size * 2) + (chunk_size * num_groups) +
!   (chunk_size * 3) + 1

!  call MPI_Bcast(chunk_data%num_obs, 1, MPI_INTEGER, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%obs_prior, size(chunk_data%obs_prior), MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%obs_inc,   size(chunk_data%obs_inc),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%net_a,   size(chunk_data%net_a),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%obs_qc,   size(chunk_data%obs_qc),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%vertvalue_obs_in_localization_coord,   size(chunk_data%vertvalue_obs_in_localization_coord),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%whichvert_real,   size(chunk_data%whichvert_real),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)

  if (detailed_timers) then
    call t_startf('DETAIL:bcast_send_chunk_call')
  endif

  call MPI_Bcast(chunk_data%bcast_buffer, size(chunk_data%bcast_buffer), MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%num_obs, 1, MPI_INTEGER, from, MPI_COMM_WORLD, iError)

  if (detailed_timers) then
    call t_stopf('DETAIL:bcast_send_chunk_call')
  endif


end subroutine broadcast_send_chunk_packed

!-------------------------------------------------------------

subroutine broadcast_send_chunk_packed_opt(from, chunk_data, ens_size, num_groups)
    use mpi
   integer, intent(in) :: from
   type(chunk_data_type) :: chunk_data

   integer :: start_offset
   integer :: iError
   integer :: num_obs
   integer, intent(in) :: ens_size
   integer, intent(in) :: num_groups
   integer :: i

   !integer :: buffer_size, comm_size
  
  if (sync_between_timers) then
     call task_sync()
  endif

   !comm_size = chunk_data%comm_obs
   !buffer_size = (comm_size * ens_size * 2) + (comm_size * num_groups) + (comm_size * 3) + 1 


  if (detailed_timers) then
     call t_startf('DETAIL:bcast_send_chunk_pack')
  endif

  start_offset = 1 
  num_obs = chunk_data%comm_obs
   !buffer_size  = size(chunk_data%bcast_buffer)

   ! obs_prior
   !chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs_prior)) = reshape(chunk_data%obs_prior, [ size(chunk_data%obs_prior) ])
   !start_offset = start_offset + size(chunk_data%obs_prior)
   do i = 1, num_obs
     chunk_data%bcast_buffer(start_offset:start_offset + ens_size -1) = chunk_data%obs_prior(:,i)
     start_offset = start_offset + ens_size
     chunk_data%bcast_buffer(start_offset:start_offset + ens_size -1) = chunk_data%obs_inc(:,i)
     start_offset = start_offset + ens_size
     chunk_data%bcast_buffer(start_offset:start_offset + num_groups -1) = chunk_data%net_a(:,i)
     start_offset = start_offset + num_groups
     chunk_data%bcast_buffer(start_offset+0) = chunk_data%obs_qc(i)
     chunk_data%bcast_buffer(start_offset+1) = chunk_data%vertvalue_obs_in_localization_coord(i)
     chunk_data%bcast_buffer(start_offset+2) = chunk_data%whichvert_real(i)
     start_offset = start_offset + 3 ! FIXME - use +4 to align data?
   end do
   chunk_data%bcast_buffer(start_offset) = num_obs ! If aligning, use -1 here

   !write(*,*) "MPIComms: Sending ", chunk_data%comm_size, size(chunk_data%bcast_buffer), start_offset, chunk_data%bcast_buffer(start_offset)

  !if ((start_offset+1) /= chunk_data%comm_size) then
  !  write(*,*) "BCast sizes : ", start_offset, chunk_data%comm_size
  !endif 

  if (detailed_timers) then
     call t_stopf('DETAIL:bcast_send_chunk_pack')
  endif

  if (detailed_timers) then
    call t_startf('DETAIL:bcast_send_chunk_call')
  endif

  call MPI_Bcast(chunk_data%bcast_buffer, chunk_data%comm_size, MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%num_obs, 1, MPI_INTEGER, from, MPI_COMM_WORLD, iError)

  if (detailed_timers) then
    call t_stopf('DETAIL:bcast_send_chunk_call')
  endif

end subroutine broadcast_send_chunk_packed_opt

!-------------------------------------------------------------

subroutine broadcast_recv_chunk(from, chunk_data)
    use mpi
   integer, intent(in) :: from
   type(chunk_data_type) :: chunk_data

   integer :: iError

!   write(*,*) "broadcast_recv_chunk - from = ", from
!  chunk_data%obs_prior = reshape(chunk_data%bcast_buffer(1:9), [ 3,3 ])

  !call MPI_Bcast(chunk_data%num_obs, 1, MPI_INTEGER, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%obs_prior, size(chunk_data%obs_prior), MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%obs_inc,   size(chunk_data%obs_inc),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%net_a,   size(chunk_data%net_a),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%obs_qc,   size(chunk_data%obs_qc),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%vertvalue_obs_in_localization_coord,   size(chunk_data%vertvalue_obs_in_localization_coord),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
  !call MPI_Bcast(chunk_data%whichvert_real,   size(chunk_data%whichvert_real),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)

   !call broadcast_recv_seqobs(from, chunk_data%obs_prior, chunk_data%obs_inc, chunk_data%net_a)
   !call broadcast_recv_seqobs(from, chunk_data%obs_qc, chunk_data%vertvalue_obs_in_localization_coord, chunk_data%whichvert_real)

end subroutine broadcast_recv_chunk

!-------------------------------------------------------------

subroutine broadcast_recv_chunk_packed(from, chunk_data)
    use mpi
   integer, intent(in) :: from
   type(chunk_data_type) :: chunk_data

   integer :: iError
   integer :: start_offset

   integer :: buffer_size 
   integer :: i
  
   if (sync_between_timers) then
     call task_sync()
   endif

   buffer_size = size(chunk_data%bcast_buffer)
   start_offset = 1
   
  if (detailed_timers) then
    call t_startf('DETAIL:bcast_recv_chunk_call')
  endif

   call MPI_Bcast(chunk_data%bcast_buffer, size(chunk_data%bcast_buffer), MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
   !call MPI_Bcast(chunk_data%num_obs, 1, MPI_INTEGER, from, MPI_COMM_WORLD, iError)

  if (detailed_timers) then
    call t_stopf('DETAIL:bcast_recv_chunk_call')
  endif

  if (detailed_timers) then
     call t_startf('DETAIL:bcast_recv_chunk_unpack')
  endif

  ! Num obs:
  chunk_data%num_obs = chunk_data%bcast_buffer(start_offset)
  start_offset = start_offset + 1

  !do i = 1, chunk_data%num_obs
  !   chunk_data%obs(i)%obs_prior = chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs(i)%obs_prior)-1)
  !   start_offset = start_offset + size(chunk_data%obs(i)%obs_prior)
  !   chunk_data%obs(i)%obs_inc = chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs(i)%obs_inc)-1)
  !   start_offset = start_offset + size(chunk_data%obs(i)%obs_inc)
  !   chunk_data%obs(i)%net_a = chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs(i)%net_a)-1)
  !   start_offset = start_offset + size(chunk_data%obs(i)%net_a)
  !   chunk_data%obs(i)%qc = chunk_data%bcast_buffer(start_offset)
  !   start_offset = start_offset + 1
  !   chunk_data%obs(i)%vertvalue_obs_in_localization_coord = chunk_data%bcast_buffer(start_offset)
  !   start_offset = start_offset + 1
  !   chunk_data%obs(i)%whichvert_real = chunk_data%bcast_buffer(start_offset)
  !   start_offset = start_offset + 1
  !end do

   ! obs_prior
   !chunk_data%obs_prior = reshape(chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs_prior)), [ size(chunk_data%obs_prior, 1), size(chunk_data%obs_prior, 2) ])
   !start_offset = start_offset + size(chunk_data%obs_prior)

   ! obs_inc
   !chunk_data%obs_inc = reshape(chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs_inc)), [ size(chunk_data%obs_inc, 1), size(chunk_data%obs_inc, 2) ])
   !start_offset = start_offset + size(chunk_data%obs_inc)

   ! net_a
   !chunk_data%net_a = reshape(chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%net_a)), [ size(chunk_data%net_a, 1), size(chunk_data%net_a, 2) ])
   !start_offset = start_offset + size(chunk_data%net_a)

   ! obs_qc
   !chunk_data%obs_qc = reshape(chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%obs_qc)), [ size(chunk_data%obs_qc, 1) ])
   !start_offset = start_offset + size(chunk_data%obs_qc)

   ! vertvalue_obs_in_localization_coord
   !chunk_data%vertvalue_obs_in_localization_coord = reshape(chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%vertvalue_obs_in_localization_coord)), [ size(chunk_data%vertvalue_obs_in_localization_coord, 1) ])
   !start_offset = start_offset + size(chunk_data%vertvalue_obs_in_localization_coord)

   ! whichvert_real
   !chunk_data%whichvert_real = reshape(chunk_data%bcast_buffer(start_offset:start_offset+size(chunk_data%whichvert_real)), [ size(chunk_data%whichvert_real, 1) ])
   !start_offset = start_offset + size(chunk_data%whichvert_real)

  ! Num obs:
  !chunk_data%num_obs = chunk_data%bcast_buffer(start_offset)

  if (detailed_timers) then
     call t_stopf('DETAIL:bcast_recv_chunk_unpack')
  endif

!   write(*,*) "broadcast_recv_chunk - from = ", from
!  chunk_data%obs_prior = reshape(chunk_data%bcast_buffer(1:9), [ 3,3 ])

!  call MPI_Bcast(chunk_data%num_obs, 1, MPI_INTEGER, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%obs_prior, size(chunk_data%obs_prior), MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%obs_inc,   size(chunk_data%obs_inc),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%net_a,   size(chunk_data%net_a),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%obs_qc,   size(chunk_data%obs_qc),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%vertvalue_obs_in_localization_coord,   size(chunk_data%vertvalue_obs_in_localization_coord),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
!  call MPI_Bcast(chunk_data%whichvert_real,   size(chunk_data%whichvert_real),   MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)

   !call broadcast_recv_seqobs(from, chunk_data%obs_prior, chunk_data%obs_inc, chunk_data%net_a)
   !call broadcast_recv_seqobs(from, chunk_data%obs_qc, chunk_data%vertvalue_obs_in_localization_coord, chunk_data%whichvert_real)

end subroutine broadcast_recv_chunk_packed

!-------------------------------------------------------------
subroutine broadcast_recv_chunk_packed_opt(from, chunk_data, ens_size, num_groups)
    use mpi
   integer, intent(in) :: from
   type(chunk_data_type) :: chunk_data

   integer :: iError
   integer :: start_offset
   integer, intent(in) :: ens_size
   integer, intent(in) :: num_groups
   integer :: i

   integer :: buffer_size, num_obs
  
   if (sync_between_timers) then
     call task_sync()
   endif

   buffer_size = size(chunk_data%bcast_buffer)
   start_offset = 1
   
  if (detailed_timers) then
    call t_startf('DETAIL:bcast_recv_chunk_call')
  endif

   call MPI_Bcast(chunk_data%bcast_buffer, chunk_data%comm_size, MPI_DOUBLE_PRECISION, from, MPI_COMM_WORLD, iError)
   !call MPI_Bcast(chunk_data%num_obs, 1, MPI_INTEGER, from, MPI_COMM_WORLD, iError)

  if (detailed_timers) then
    call t_stopf('DETAIL:bcast_recv_chunk_call')
  endif

  if (detailed_timers) then
     call t_startf('DETAIL:bcast_recv_chunk_unpack')
  endif

  num_obs = chunk_data%bcast_buffer(chunk_data%comm_size)
  !write(*,*) "Receive : num_obs = ", num_obs, chunk_data%comm_size, ens_size
   do i = 1, num_obs
     chunk_data%obs_prior(:,i) = chunk_data%bcast_buffer(start_offset:start_offset + ens_size -1)
     start_offset = start_offset + ens_size

     chunk_data%obs_inc(:,i) = chunk_data%bcast_buffer(start_offset:start_offset + ens_size -1 )
     start_offset = start_offset + ens_size

     chunk_data%net_a(:,i) = chunk_data%bcast_buffer(start_offset:start_offset + num_groups -1)
     start_offset = start_offset + num_groups

     chunk_data%obs_qc(i) = chunk_data%bcast_buffer(start_offset+0)
     chunk_data%vertvalue_obs_in_localization_coord(i) = chunk_data%bcast_buffer(start_offset+1)
     chunk_data%whichvert_real(i) = chunk_data%bcast_buffer(start_offset+2) 
     start_offset = start_offset + 3 ! FIXME - use +4 to align data?
   end do
   !chunk_data%num_obs = chunk_data%bcast_buffer(start_offset) ! If aligning, use -1 here

  if (detailed_timers) then
     call t_stopf('DETAIL:bcast_recv_chunk_unpack')
  endif
end subroutine broadcast_recv_chunk_packed_opt


!-------------------------------------------------------------
subroutine get_obs_from_color(colors, i, obs_list, last_rank)
  type(colors_type), intent(in) :: colors
  integer,           intent(in) :: i
  integer, dimension(:), allocatable, intent(inout) :: obs_list
  integer, intent(out) :: last_rank ! hack for now

  integer :: color_size
  integer :: chunks, chunks_per_rank, my_num_obs

  integer :: numRanks, mpiRank, iError
  integer :: k, remaining_obs
  integer, save :: current_rank = 0  ! Save so we resume where we left off at the next round

  integer, dimension(:), allocatable :: obs_per_rank

  integer :: start_ob, end_ob

  ! Deallocate if we'd already allocated:
  if (allocated(obs_list)) then
     deallocate(obs_list)
  endif

  ! Get the size of this color -- this is a bit hackish, would ANY work better?
  color_size = sum(colors%obs_color, colors%obs_color==i) / i

  ! Get the number of chunks
  chunks = (color_size + colors%chunk_size - 1) / colors%chunk_size

  ! Get the number of chunks per rank
  chunks_per_rank = (chunks + task_count() - 1) / task_count()
  if (chunks_per_rank > 1) then
       write(*,*) "Error - don't yet support >1 chunk per rank.. quitting."
       call MPI_Finalize(iError)
       stop
  endif


  ! Now allocate based on chunks_per_rank * chunk_size
  allocate(obs_list(chunks_per_rank * colors%chunk_size))

  ! set it to 0 (invalid ob): 
  obs_list = 0

  ! Now assign... for now, with no offset - always start at rank 0:
  ! Note: We're doing this the dumb way with a loop for now; there's a better
  ! way, but I don't want to waste time figuring it out until I have something
  ! working!

  remaining_obs = color_size
  numRanks = task_count()
  mpiRank = my_task_id()

  allocate(obs_per_rank(numRanks)) ! A value per rank so we know what each rank has
  obs_per_rank = 0

  ! Cheat - setting current_rank to 0 ensures we always start at rank 0... this
  ! is easier for now since we only will need to loop from 0->x, instead of
  ! (potentially) y->(some value less than y due to wrap-around in assignment).
  current_rank = 0

  do while (remaining_obs > 0) 
   if (remaining_obs > colors%chunk_size) then
      obs_per_rank(current_rank+1) = obs_per_rank(current_rank+1) + colors%chunk_size
      remaining_obs = remaining_obs - colors%chunk_size
      current_rank = MOD(current_rank + 1, numRanks)
    else
      obs_per_rank(current_rank+1) = obs_per_rank(current_rank+1) + remaining_obs
      remaining_obs = 0
      current_rank = MOD(current_rank + 1, numRanks)
    endif
  enddo

  last_rank = current_rank 

  ! debug printing:
  do k = 0, numRanks-1
     if (k == mpiRank) then
       !write(*,*) "Rank: ",mpiRank," has ",obs_per_rank(k+1)
     endif
  enddo

  ! Actual assignment:
  if (mpiRank < current_rank) then
    start_ob = sum(obs_per_rank(1:mpiRank)) + 1
    end_ob = sum(obs_per_rank(1:mpiRank+1))
    do k = 1, obs_per_rank(mpiRank+1)
       obs_list(k) = start_ob + k - 1
    enddo
  endif



  !write(*,*) "C(",i,") Rank# ",mpiRank," Start/End => ",start_ob,end_ob,last_rank
  !write(*,*) "C(",i,") Rank# ",mpiRank," LIST => ",obs_list(:)

end subroutine get_obs_from_color


!subroutine assign_chunks_to_ranks(colors)
! type(coloring_type), intent(inout) :: colors
!
! integer :: myRank, numRanks
! integer :: current = 0
! integer :: i
!
! myRank = my_task_id()
! numRanks = task_count()
!
! allocate(colors%owner(colors%num_chunks))
! 
! do i = 1, colors%num_chunks
!    colors%owner(i) = MOD((i-1), numRanks)
! end do
!
!end subroutine assign_chunks_to_ranks


!-------------------------------------------------------------

!logical function rank_has_color(colors, i)
!  type(coloring_type), intent(in) :: colors
!  integer, intent(in) :: i
!
!  integer :: my_rank
!
!  my_rank = my_task_id()
!  if (colors%owner(i) == my_rank) then
!    rank_has_color = .true.
!  else
!    rank_has_color = .false.
!  endif
!
!end function rank_has_color
!
!-------------------------------------------------------------

!subroutine get_my_obs(colors, i, obs_set, obs_set_size)
!   type(coloring_type), intent(in) :: colors
!   integer, intent(in) :: i
!   integer, dimension(:), intent(out) :: obs_set ! Note, just using a large max size for now
!   integer, intent(out) :: obs_set_size
!
!   obs_set = 0
!   obs_set(1) = 1
!   obs_set_size = 1
!
!end subroutine get_my_obs



!-------------------------------------------------------------


!-----------------------------------------------------------------

subroutine obs_increment(ens_in, ens_size, obs, obs_var, obs_inc, &
   inflate, my_cov_inflate, my_cov_inflate_sd, net_a)

! Given the ensemble prior for an observation, the observation, and
! the observation error variance, computes increments and adjusts
! observation space inflation values

integer,                     intent(in)    :: ens_size
real(r8),                    intent(in)    :: ens_in(ens_size), obs, obs_var
real(r8),                    intent(out)   :: obs_inc(ens_size)
type(adaptive_inflate_type), intent(inout) :: inflate
real(r8),                    intent(inout) :: my_cov_inflate, my_cov_inflate_sd
real(r8),                    intent(out)   :: net_a

real(r8) :: ens(ens_size), inflate_inc(ens_size)
real(r8) :: prior_mean, prior_var, new_val(ens_size)
integer  :: i, ens_index(ens_size), new_index(ens_size)

real(r8) :: rel_weights(ens_size)

real(r8) :: testval3 = 0.0


! Copy the input ensemble to something that can be modified
ens = ens_in

! Null value of net spread change factor is 1.0
net_a = 0.0_r8

! Compute prior variance and mean from sample
prior_mean = sum(ens) / ens_size
prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)

!write(*,*) "OBS_INCREMENT() - priors: ", prior_mean, prior_var
!write(*,*) "OBS_INCREMENT1 - info: ", filter_kind, obs
!write(*,*) "OBS_INCREMENT2 - info: ", obs_var


! If observation space inflation is being done, compute the initial 
! increments and update the inflation factor and its standard deviation
! as needed. my_cov_inflate < 0 means don't do any of this.
if(do_obs_inflate(inflate)) then
   ! If my_cov_inflate_sd is <= 0, just retain current my_cov_inflate setting
   if(my_cov_inflate_sd > 0.0_r8) & 
      ! Gamma set to 1.0 because no distance for observation space
      call update_inflation(inflate, my_cov_inflate, my_cov_inflate_sd, prior_mean, &
         prior_var, obs, obs_var, gamma = 1.0_r8)

   ! Now inflate the ensemble and compute a preliminary inflation increment
   call inflate_ens(inflate, ens, prior_mean, my_cov_inflate, prior_var)
   ! Keep the increment due to inflation alone 
   inflate_inc = ens - ens_in

   ! Need to recompute variance if non-deterministic inflation (mean is unchanged)
   if(.not. deterministic_inflate(inflate)) &
      prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)
endif

! If obs_var == 0, delta function.  The mean becomes obs value with no spread.
! If prior_var == 0, obs has no effect.  The increments are 0.
! If both obs_var and prior_var == 0 there is no right thing to do, so Stop.
if ((obs_var == 0.0_r8) .and. (prior_var == 0.0_r8)) then

   ! fail if both obs variance and prior spreads are 0.
   write(msgstring,  *) 'Observation value is ', obs, ' ensemble mean value is ', prior_mean
   write(msgstring2, *) 'The observation has 0.0 error variance, and the ensemble members have 0.0 spread.'
   write(msgstring3, *) 'These require inconsistent actions and the algorithm cannot continue.'
   call error_handler(E_ERR, 'obs_increment', msgstring, &
           source, revision, revdate, text2=msgstring2, text3=msgstring3)

else if (obs_var == 0.0_r8) then

   ! new mean is obs value, so increments are differences between obs
   ! value and current value.  after applying obs, all state will equal obs.
   obs_inc(:) = obs - ens

else if (prior_var == 0.0_r8) then

   ! if all state values are the same, nothing changes.
   obs_inc(:) = 0.0_r8

else

   ! Call the appropriate filter option to compute increments for ensemble
   ! note that at this point we've taken care of the cases where either the
   ! obs_var or the prior_var is 0, so the individual routines no longer need
   ! to have code to test for those cases.
   if(filter_kind == 1) then
      call obs_increment_eakf(ens, ens_size, prior_mean, prior_var, &
         obs, obs_var, obs_inc, net_a)
   else if(filter_kind == 2) then
      call obs_increment_enkf(ens, ens_size, prior_var, obs, obs_var, obs_inc)
   else if(filter_kind == 3) then
      call obs_increment_kernel(ens, ens_size, obs, obs_var, obs_inc)
   else if(filter_kind == 4) then
      call obs_increment_particle(ens, ens_size, obs, obs_var, obs_inc)
   else if(filter_kind == 5) then
      call obs_increment_ran_kf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
   else if(filter_kind == 6) then
      call obs_increment_det_kf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
   else if(filter_kind == 7) then
      call obs_increment_boxcar(ens, ens_size, obs, obs_var, obs_inc, rel_weights)
   else if(filter_kind == 8) then
      call obs_increment_rank_histogram(ens, ens_size, prior_var, obs, obs_var, obs_inc)
   else 
      call error_handler(E_ERR,'obs_increment', &
                 'Illegal value of filter_kind in assim_tools namelist [1-8 OK]', &
                 source, revision, revdate)
   endif
endif

!testval3 = sum(obs_inc)
!write(*,*) "obs_increment SUM = ", testval3

! Add in the extra increments if doing observation space covariance inflation
if(do_obs_inflate(inflate)) obs_inc = obs_inc + inflate_inc

! To minimize regression errors, may want to sort to minimize increments
! This makes sense for any of the non-deterministic algorithms
! By doing it here, can take care of both standard non-deterministic updates
! plus non-deterministic obs space covariance inflation. This is expensive, so
! don't use it if it's not needed.
if (sort_obs_inc) then
   new_val = ens_in + obs_inc
   ! Sorting to make increments as small as possible
   call index_sort(ens_in, ens_index, ens_size)
   call index_sort(new_val, new_index, ens_size)
   do i = 1, ens_size
      obs_inc(ens_index(i)) = new_val(new_index(i)) - ens_in(ens_index(i))
   end do
endif

! Get the net change in spread if obs space inflation was used
if(do_obs_inflate(inflate)) net_a = net_a * sqrt(my_cov_inflate)


end subroutine obs_increment



subroutine obs_increment_eakf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc, a)
!========================================================================
!
! EAKF version of obs increment

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_mean, prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)
real(r8), intent(out) :: a

real(r8) :: new_mean, var_ratio

! Compute the new mean
var_ratio = obs_var / (prior_var + obs_var)
new_mean  = var_ratio * (prior_mean  + prior_var*obs / obs_var)

! Compute sd ratio and shift ensemble
a = sqrt(var_ratio)
obs_inc = a * (ens - prior_mean) + new_mean - ens

end subroutine obs_increment_eakf


subroutine obs_increment_ran_kf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
!========================================================================
!
! Forms a random sample of the Gaussian from the update equations.
! This is very close to what a true 'ENSEMBLE' Kalman Filter would 
! look like. Note that outliers, multimodality, etc., get tossed.

integer,   intent(in)  :: ens_size
real(r8),  intent(in)  :: prior_mean, prior_var
real(r8),  intent(in)  :: ens(ens_size), obs, obs_var
real(r8),  intent(out) :: obs_inc(ens_size)

real(r8) :: new_mean, var_ratio
real(r8) :: temp_mean, temp_var, new_ens(ens_size), new_var
integer  :: i

var_ratio = obs_var / (prior_var + obs_var)
new_var = var_ratio * prior_var
new_mean  = var_ratio * (prior_mean  + prior_var*obs / obs_var)

! This will reproduce exactly for multiple runs with the same task count,
! but WILL NOT reproduce for a different number of MPI tasks.
! To make it independent of the number of MPI tasks, it would need to
! use the global ensemble number or something else that remains constant
! as the processor count changes.  this is not currently an argument to
! this function and so we are not trying to make it task-count invariant.

! Form a random sample from the updated distribution
! Then adjust the mean (what about adjusting the variance?)!
! Definitely need to sort with this; sort is done in main obs_increment
if(first_inc_ran_call) then
   call init_random_seq(inc_ran_seq, my_task_id() + 1)
   first_inc_ran_call = .false.
endif

do i = 1, ens_size
   new_ens(i) = random_gaussian(inc_ran_seq, new_mean, sqrt(prior_var*var_ratio))
end do

! Adjust the mean of the new ensemble
temp_mean = sum(new_ens) / ens_size
new_ens(:) = new_ens(:) - temp_mean + new_mean

! Compute prior variance and mean from sample
temp_var  = sum((new_ens - new_mean)**2) / (ens_size - 1)
! Adjust the variance, also
new_ens = (new_ens - new_mean) * sqrt(new_var / temp_var) + new_mean

! Get the increments
obs_inc = new_ens - ens

end subroutine obs_increment_ran_kf



subroutine obs_increment_det_kf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
!========================================================================
!
! Does a deterministic ensemble layout for the updated Gaussian.
! Note that all outliers, multimodal behavior, etc. get tossed.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: prior_mean, prior_var
real(r8), intent(in)  :: ens(ens_size), obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

real(r8) :: new_mean, var_ratio, temp_var, new_ens(ens_size), new_var
integer :: i

var_ratio = obs_var / (prior_var + obs_var)
new_var = var_ratio * prior_var
new_mean = var_ratio * (prior_mean  + prior_var*obs / obs_var)

! Want a symmetric distribution with kurtosis 3 and variance new_var and mean new_mean
if(ens_size /= 20) then
   write(*, *) 'EXPERIMENTAL version obs_increment_det_kf only works for ens_size 20 now'
   stop
endif

! This has kurtosis of 3.0, verify again from initial uniform
!new_ens(1) = -2.146750_r8
!new_ens(2) = -1.601447_r8
!new_ens(3) = -1.151582_r8
!new_ens(4) = -0.7898650_r8
!new_ens(5) = -0.5086292_r8
!new_ens(6) = -0.2997678_r8
!new_ens(7) = -0.1546035_r8
!new_ens(8) = -6.371084E-02_r8
!new_ens(9) = -1.658448E-02_r8
!new_ens(10) = -9.175255E-04_r8

! This has kurtosis of 3.0, verify again from initial inverse gaussian
!new_ens(1) = -2.188401_r8
!new_ens(2) = -1.502174_r8
!new_ens(3) = -1.094422_r8
!new_ens(4) = -0.8052422_r8
!new_ens(5) = -0.5840152_r8
!new_ens(6) = -0.4084518_r8
!new_ens(7) = -0.2672727_r8
!new_ens(8) = -0.1547534_r8
!new_ens(9) = -6.894587E-02_r8
!new_ens(10) = -1.243549E-02_r8

! This has kurtosis of 2.0, verify again 
new_ens(1) = -1.789296_r8
new_ens(2) = -1.523611_r8
new_ens(3) = -1.271505_r8
new_ens(4) = -1.033960_r8
new_ens(5) = -0.8121864_r8
new_ens(6) = -0.6077276_r8
new_ens(7) = -0.4226459_r8
new_ens(8) = -0.2598947_r8
new_ens(9) = -0.1242189_r8
new_ens(10) = -2.539018E-02_r8

! This has kurtosis of 1.7, verify again 
!new_ens(1) = -1.648638_r8
!new_ens(2) = -1.459415_r8
!new_ens(3) = -1.272322_r8
!new_ens(4) = -1.087619_r8
!new_ens(5) = -0.9056374_r8
!new_ens(6) = -0.7268229_r8
!new_ens(7) = -0.5518176_r8
!new_ens(8) = -0.3816142_r8
!new_ens(9) = -0.2179997_r8
!new_ens(10) = -6.538583E-02_r8
do i = 11, 20
   new_ens(i) = -1.0_r8 * new_ens(20 + 1 - i)
end do

! Right now, this ensemble has mean 0 and some variance
! Compute prior variance and mean from sample
temp_var  = sum((new_ens)**2) / (ens_size - 1)

! Adjust the variance of this ensemble to match requirements and add in the mean
new_ens = new_ens * sqrt(new_var / temp_var) + new_mean

! Get the increments
obs_inc = new_ens - ens

end subroutine obs_increment_det_kf




subroutine obs_increment_particle(ens, ens_size, obs, obs_var, obs_inc)
!------------------------------------------------------------------------
!
! A observation space only particle filter implementation for a
! two step sequential update filter. Second version, 2 October, 2003.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

real(r8) :: weight(ens_size), rel_weight(ens_size), cum_weight(0:ens_size)
real(r8) :: base, frac, new_val(ens_size), weight_sum
integer  :: i, j, indx(ens_size)

! Begin by computing a weight for each of the prior ensemble members
do i = 1, ens_size
   weight(i) = exp(-1.0_r8 * (ens(i) - obs)**2 / (2.0_r8 * obs_var))
end do

! Compute relative weight for each ensemble member
weight_sum = sum(weight)
do i = 1, ens_size
   rel_weight(i) = weight(i) / weight_sum
end do

! Compute cumulative weights at boundaries
cum_weight(0) = 0.0_r8
do i = 1, ens_size
   cum_weight(i) = cum_weight(i - 1) + rel_weight(i)
!   write(*,'(1x,i3,3(e10.4,1x))') i, weight(i), rel_weight(i), cum_weight(i)
end do
! Fix up for round-off error if any
cum_weight(ens_size) = 1.0_r8

! Do a deterministic implementation: just divide interval into ens_size parts and see
! which interval this is in (careful to offset; not start at 0)
base = 1.0_r8 / (ens_size * 2.0_r8)

do i = 1, ens_size

   frac = base + (i - 1.0_r8) / ens_size

   ! Now search in the cumulative range to see where this frac falls
   ! Can make this search more efficient by limiting base
   do j = 1, ens_size
      if(cum_weight(j - 1) < frac .and. frac < cum_weight(j)) then
         indx(i) = j
!         write(*, *) i, frac, 'gets index ', j
         goto 111
      end if
   end do

111 continue

end do

! Set the new values for the ensemble members
do i = 1, ens_size
   new_val(i) = ens(indx(i))
!   write(*, *) 'new_val ', i, new_val(i)
end do

! Generate increments
obs_inc = new_val - ens

end subroutine obs_increment_particle



subroutine obs_increment_enkf(ens, ens_size, prior_var, obs, obs_var, obs_inc)
!========================================================================
! subroutine obs_increment_enkf(ens, ens_size, obs, obs_var, obs_inc)
!

! ENKF version of obs increment

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

real(r8) :: obs_var_inv, prior_var_inv, new_var, new_mean(ens_size)
! real(r8) :: sx, s_x2
real(r8) :: temp_mean, temp_obs(ens_size)
integer  :: i

! Compute mt_rinv_y (obs error normalized by variance)
obs_var_inv = 1.0_r8 / obs_var
prior_var_inv = 1.0_r8 / prior_var

new_var       = 1.0_r8 / (prior_var_inv + obs_var_inv)

! If this is first time through, need to initialize the random sequence.
! This will reproduce exactly for multiple runs with the same task count,
! but WILL NOT reproduce for a different number of MPI tasks.
! To make it independent of the number of MPI tasks, it would need to
! use the global ensemble number or something else that remains constant
! as the processor count changes.  this is not currently an argument to
! this function and so we are not trying to make it task-count invariant.
if(first_inc_ran_call) then
   call init_random_seq(inc_ran_seq, my_task_id() + 1)
   first_inc_ran_call = .false.
endif

! Generate perturbed obs
do i = 1, ens_size
    temp_obs(i) = random_gaussian(inc_ran_seq, obs, sqrt(obs_var))
end do

! Move this so that it has original obs mean
temp_mean = sum(temp_obs) / ens_size
temp_obs(:) = temp_obs(:) - temp_mean + obs

! Loop through pairs of priors and obs and compute new mean
do i = 1, ens_size
   new_mean(i) = new_var * (prior_var_inv * ens(i) + temp_obs(i) / obs_var)
   obs_inc(i)  = new_mean(i) - ens(i)
end do

! Can also adjust mean (and) variance of final sample; works fine
!sx         = sum(new_mean)
!s_x2       = sum(new_mean * new_mean)
!temp_mean = sx / ens_size
!temp_var  = (s_x2 - sx**2 / ens_size) / (ens_size - 1)
!new_mean = (new_mean - temp_mean) * sqrt(new_var / temp_var) + updated_mean
!obs_inc = new_mean - ens


end subroutine obs_increment_enkf



subroutine obs_increment_kernel(ens, ens_size, obs, obs_var, obs_inc)
!========================================================================
! subroutine obs_increment_kernel(ens, ens_size, obs, obs_var, obs_inc)
!

! Kernel version of obs increment

integer, intent(in)             :: ens_size
real(r8), intent(in)            :: ens(ens_size), obs, obs_var
real(r8), intent(out)           :: obs_inc(ens_size)

real(r8) :: obs_var_inv
real(r8) :: prior_mean, prior_cov_inv, new_cov, prior_cov
real(r8) :: sx
real(r8) :: weight(ens_size), new_mean(ens_size)
real(r8) :: cum_weight, total_weight, cum_frac(ens_size)
real(r8) :: unif, norm, new_member(ens_size)

integer :: i, j, kernel

! Compute mt_rinv_y (obs error normalized by variance)
obs_var_inv = 1.0_r8 / obs_var

! Compute prior mean and covariance
sx         = sum(ens)
prior_mean = sx / ens_size
prior_cov  = sum((ens - prior_mean)**2) / (ens_size - 1)

prior_cov     = prior_cov / 10.0_r8     ! For kernels, scale the prior covariance
prior_cov_inv = 1.0_r8 / prior_cov

! Compute new covariance once for these kernels
new_cov = 1.0_r8 / (prior_cov_inv + obs_var_inv)

! New mean is computed ens_size times as is weight
do i = 1, ens_size
   new_mean(i) = new_cov*(prior_cov_inv * ens(i) + obs / obs_var)
   weight(i) =  2.71828_r8 ** (-0.5_r8 * (ens(i)**2 * prior_cov_inv + &
      obs**2 * obs_var_inv - new_mean(i)**2 / new_cov))
end do

! Compute total weight
total_weight = sum(weight)
cum_weight   = 0.0_r8
do i = 1, ens_size
   cum_weight  = cum_weight + weight(i)
   cum_frac(i) = cum_weight / total_weight
end do

! If this is first time through, need to initialize the random sequence.
! This will reproduce exactly for multiple runs with the same task count,
! but WILL NOT reproduce for a different number of MPI tasks.
! To make it independent of the number of MPI tasks, it would need to
! use the global ensemble number or something else that remains constant
! as the processor count changes.  this is not currently an argument to
! this function and so we are not trying to make it task-count invariant.
if(first_inc_ran_call) then
   call init_random_seq(inc_ran_seq, my_task_id() + 1)
   first_inc_ran_call = .false.
endif

! Generate a uniform random number and a Gaussian for each new member
do i = 1, ens_size
   unif = random_uniform(inc_ran_seq)
   ! Figure out which kernel it's in
   whichk: do j = 1, ens_size
      if(unif < cum_frac(j)) then
         kernel = j
         exit whichk
      end if
   end do whichk

   ! Next calculate a unit normal in this kernel
   norm = random_gaussian(inc_ran_seq, 0.0_r8, sqrt(new_cov))
   ! Now generate the new ensemble member
   new_member(i) = new_mean(kernel) + norm
end do

! Generate the increments
obs_inc = new_member - ens

end subroutine obs_increment_kernel



subroutine update_from_obs_inc(obs, obs_prior_mean, obs_prior_var, obs_inc, &
               state, ens_size, state_inc, reg_coef, net_a, correl_out)
!========================================================================

! Does linear regression of a state variable onto an observation and
! computes state variable increments from observation increments

integer,            intent(in)    :: ens_size
real(r8),           intent(in)    :: obs(ens_size), obs_inc(ens_size)
real(r8),           intent(in)    :: obs_prior_mean, obs_prior_var
real(r8),           intent(in)    :: state(ens_size)
real(r8),           intent(out)   :: state_inc(ens_size), reg_coef
real(r8),           intent(inout) :: net_a
real(r8), optional, intent(inout) :: correl_out

real(r8) :: obs_state_cov, intermed
real(r8) :: restoration_inc(ens_size), state_mean, state_var, correl
real(r8) :: factor, exp_true_correl, mean_factor

logical :: missing_in_state = .false.
logical :: missing_in_obs   = .false.
logical :: missing_in_incs  = .false.

! FIXME if there are some missing values in the state or obs
! we cannot just include them in the math ... not sure if this
! routine can be called in these situations ... but ...

if (2 == 1) then ! DEBUG VERBOSE 
   missing_in_state = any(state   == MISSING_R8)
   missing_in_obs   = any(obs     == MISSING_R8)
   missing_in_incs  = any(obs_inc == MISSING_R8)

   if ( missing_in_state .or. missing_in_obs .or. missing_in_incs ) then
      write(msgstring,*) 'Should not have missing values at this point'
      call error_handler(E_ERR,'update_from_obs_inc',msgstring,source,revision,revdate)
   endif
endif

! For efficiency, just compute regression coefficient here unless correl is needed

state_mean = sum(state) / ens_size
obs_state_cov = sum( (state - state_mean) * (obs - obs_prior_mean) ) / (ens_size - 1)

if (obs_prior_var > 0.0_r8) then
   reg_coef = obs_state_cov/obs_prior_var
else
   reg_coef = 0.0_r8
endif

! If correl_out is present, need correl for adaptive inflation
! Also needed for file correction below.

! WARNING: we have had several different numerical problems in this
! section, especially with users running in single precision floating point.
! Be very cautious if changing any code in this section, taking into
! account underflow and overflow for 32 bit floats.

if(present(correl_out) .or. sampling_error_correction) then
   if (obs_state_cov == 0.0_r8 .or. obs_prior_var <= 0.0_r8) then
      correl = 0.0_r8
   else
      state_var = sum((state - state_mean)**2) / (ens_size - 1)
      if (state_var <= 0.0_r8) then
         correl = 0.0_r8
      else
         intermed = sqrt(obs_prior_var) * sqrt(state_var)
         if (intermed <= 0.0_r8) then
            correl = 0.0_r8
         else
            correl = obs_state_cov / intermed
         endif
      endif
   endif
   if(correl >  1.0_r8) correl =  1.0_r8
   if(correl < -1.0_r8) correl = -1.0_r8
endif
if(present(correl_out)) correl_out = correl


! Get the expected actual correlation and the regression weight reduction factor
if(sampling_error_correction) then
   call get_correction_from_table(correl, mean_factor, exp_true_correl, ens_size)
   ! Watch out for division by zero; if correl is really small regression is safely 0
   if(abs(correl) > 0.001_r8) then
      reg_coef = reg_coef * (exp_true_correl / correl) * mean_factor
   else
      reg_coef = 0.0_r8
   endif
   correl = exp_true_correl
endif



! Then compute the increment as product of reg_coef and observation space increment
state_inc = reg_coef * obs_inc


! Spread restoration algorithm option
if(spread_restoration) then
   ! Don't use this to reduce spread at present (should revisit this line)
   if(net_a > 1.0_r8) net_a = 1.0_r8

   ! Default restoration increment is 0.0
   restoration_inc = 0.0_r8

   ! Compute the factor by which to inflate
   ! These come from correl_error.f90 in system_simulation and the files ens??_pairs and
   ! ens_pairs_0.5 in work under system_simulation. Assume a linear reduction from 1
   ! as a function of the net_a. Assume that the slope of this reduction is a function of
   ! the reciprocal of the ensemble_size (slope = 0.80 / ens_size). These are empirical
   ! for now. See also README in spread_restoration_paper documentation.
   !!!factor = 1.0_r8 / (1.0_r8 + (net_a - 1.0_r8) * (0.8_r8 / ens_size)) - 1.0_r8
   factor = 1.0_r8 / (1.0_r8 + (net_a - 1.0_r8) / (-2.4711_r8 + 1.6386_r8 * ens_size)) - 1.0_r8
   !!!factor = 1.0_r8 / (1.0_r8 + (net_a**2 - 1.0_r8) * (-0.0111_r8 + .8585_r8 / ens_size)) - 1.0_r8

   ! Variance restoration
   state_mean = sum(state) / ens_size
   restoration_inc = factor * (state - state_mean)
   state_inc = state_inc + restoration_inc
endif

!! NOTE: if requested to be returned, correl_out is set further up in the
!! code, before the sampling error correction, if enabled, is applied.
!! this means it's returning a different larger value than the correl 
!! being returned here.  it's used by the adaptive inflation and so the
!! inflation will see a slightly different correlation value.  it isn't
!! clear that this is a bad thing; it means the inflation might be a bit
!! larger than it would otherwise.  before we move any code this would
!! need to be studied to see what the real impact would be.

end subroutine update_from_obs_inc


!------------------------------------------------------------------------

subroutine get_correction_from_table(scorrel, mean_factor, expected_true_correl, ens_size)

real(r8),  intent(in) :: scorrel
real(r8), intent(out) :: mean_factor, expected_true_correl
integer,  intent(in)  :: ens_size

! Uses interpolation to get correction factor into the table

integer             :: iunit, i, low_indx, high_indx
real(r8)            :: temp, temp2, correl, fract, low_correl, low_exp_correl, low_alpha
real(r8)            :: high_correl, high_exp_correl, high_alpha

logical, save :: first_time = .true.

if (first_time) then
   call read_sampling_error_correction(ens_size, exp_true_correl, alpha)
   first_time = .false.
endif

! Interpolate to get values of expected correlation and mean_factor
if(scorrel < -1.0_r8) then
   correl = -1.0_r8
   mean_factor = 1.0_r8
else if(scorrel > 1.0_r8) then
   correl = 1.0_r8
   mean_factor = 1.0_r8
else if(scorrel <= -0.995_r8) then
   fract = (scorrel + 1.0_r8) / 0.005_r8
   correl = (exp_true_correl(1) + 1.0_r8) * fract - 1.0_r8
   mean_factor = (alpha(1) - 1.0_r8) * fract + 1.0_r8
else if(scorrel >= 0.995_r8) then
   fract = (scorrel - 0.995_r8) / 0.005_r8
   correl = (1.0_r8 - exp_true_correl(sec_table_size)) * fract + exp_true_correl(sec_table_size)
   mean_factor = (1.0_r8 - alpha(sec_table_size)) * fract + alpha(sec_table_size)
else
   ! given the ifs above, the floor() computation below for low_indx 
   ! should always result in a value in the range 1 to 199.  but if this
   ! code is compiled with r8=r4 (single precision reals) it turns out
   ! to be possible to get values a few bits below 0 which results in
   ! a very large negative integer.  the limit tests below ensure the
   ! index stays in a legal range.
   low_indx = floor((scorrel + 0.995_r8) / 0.01_r8 + 1.0_r8)
   if (low_indx <   1) low_indx =   1
   if (low_indx > 199) low_indx = 199
   low_correl = -0.995_r8 + (low_indx - 1) * 0.01_r8
   low_exp_correl = exp_true_correl(low_indx)
   low_alpha = alpha(low_indx)
   high_indx = low_indx + 1
   high_correl = low_correl + 0.01_r8
   high_exp_correl = exp_true_correl(high_indx)
   high_alpha = alpha(high_indx)
   fract = (scorrel - low_correl) / (high_correl - low_correl)
   correl = (high_exp_correl - low_exp_correl) * fract + low_exp_correl
   mean_factor = (high_alpha - low_alpha) * fract + low_alpha
endif

expected_true_correl = correl 

! Don't want Monte Carlo interpolation problems to put us outside of a
! ratio between 0 and 1 for expected_true_correl / sample_correl
! If they have different signs, expected should just be 0
if(expected_true_correl * scorrel <= 0.0_r8) then
   expected_true_correl = 0.0_r8
else if(abs(expected_true_correl) > abs(scorrel)) then
   ! If same sign, expected should not be bigger in absolute value
   expected_true_correl = scorrel
endif 

end subroutine get_correction_from_table



subroutine obs_increment_boxcar(ens, ens_size, obs, obs_var, obs_inc, rel_weight)
!------------------------------------------------------------------------
!
! An observation space update that uses a set of boxcar kernels plus two
! half-gaussians on the wings to represent the prior distribution. If N is
! the ensemble size, 1/(N+1) of the mass is placed between each ensemble
! member. This is reminiscent of the ranked historgram approach for 
! evaluating ensembles. The prior distribution on the wings is 
! represented by a half gaussian with mean being the outermost ensemble
! member (left or right) and variance being somewhat arbitrarily chosen
! as half the total ensemble sample variance. A particle
! filter like algorithm is then used for the update. The weight associated
! with each prior ensemble member is computed by evaluating the likelihood.
! For the interior, the domain for each boxcar is divided in half and each
! half is associated with the nearest ensemble member. The updated mass in
! each half box is the product of the prior mass and the ensemble weight.
! In the wings, the observation likelihood gaussian is convolved with the
! prior gaussian to get an updated weighted gaussian that is assumed to 
! represent the posterior outside of the outermost ensemble members. The
! updated ensemble members are chosen so that 1/(N+1) of the updated
! mass is between each member and also on the left and right wings. This
! algorithm is able to deal well with outliers, bimodality and other
! non-gaussian behavior in observation space. It could also be modified to
! deal with non-gaussian likelihoods in the future.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)
real(r8), intent(out) :: rel_weight(ens_size)

integer  :: i, e_ind(ens_size), lowest_box, j
real(r8) :: sx, prior_mean, prior_var, prior_var_d2
real(r8) :: var_ratio, new_var, new_sd, umass, left_weight, right_weight
real(r8) :: mass(2*ens_size), weight(ens_size), cumul_mass(0:2*ens_size)
real(r8) :: new_mean_left, new_mean_right, prod_weight_left, prod_weight_right
real(r8) :: new_ens(ens_size), mass_sum, const_term
real(r8) :: x(1:2*ens_size - 1), sort_inc(ens_size)

! The factor a is not defined for this filter for now (could it be???)

! The relative weights could be used for a multi-dimensional particle-type
! update using update_ens_from_weights. There are algorithmic challenges
! with outliers so this is not currently a supported option. For now,
! rel_weight is simply set to 0 and is unused elsewhere.
rel_weight = 0.0_r8

! Do an index sort of the ensemble members; Need sorted ensemble
call index_sort(ens, e_ind, ens_size)

! Prior distribution is boxcar in the central bins with 1/(n+1) density
! in each intermediate bin. BUT, distribution on the wings is a normal with
! 1/(n + 1) of the mass on each side.

! Begin by computing a weight for each of the prior ensemble membersA
! This is just evaluating the gaussian likelihood
const_term = 1.0_r8 / (sqrt(2.0_r8 * PI) * sqrt(obs_var))
do i = 1, ens_size
   weight(i) = const_term * exp(-1.0_r8 * (ens(i) - obs)**2 / (2.0_r8 * obs_var))
end do

! Compute the points that bound all the updated mass boxes; start with ensemble
do i = 1, ens_size
   x(2*i - 1) = ens(e_ind(i))
end do
! Compute the mid-point interior boundaries; these are halfway between ensembles
do i = 2, 2*ens_size - 2, 2
   x(i) = (x(i - 1) + x(i + 1)) / 2.0_r8
end do

! Compute the s.d. of the ensemble for getting the gaussian wings
sx         = sum(ens)
prior_mean = sx / ens_size
prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)

! Need to normalize the wings so they have 1/(ens_size + 1) mass outside
! Since 1/2 of a normal is outside, need to multiply by 2 / (ens_size + 1)

! Need some sort of width for the boundary kernel, try 1/2 the VAR for now
prior_var_d2 = prior_var / 2.0_r8

! Compute the product of the obs error gaussian with the prior gaussian (EAKF)
! Left wing first
var_ratio = obs_var / (prior_var_d2 + obs_var)
new_var = var_ratio * prior_var_d2
new_sd = sqrt(new_var)
new_mean_left  = var_ratio * (ens(e_ind(1))  + prior_var_d2*obs / obs_var)
new_mean_right  = var_ratio * (ens(e_ind(ens_size))  + prior_var_d2*obs / obs_var)
! REMEMBER, this product has an associated weight which must be taken into account
! See Anderson and Anderson for this weight term (or tutorial kernel filter)
prod_weight_left =  2.71828_r8 ** (-0.5_r8 * (ens(e_ind(1))**2 / prior_var_d2 + &
      obs**2 / obs_var - new_mean_left**2 / new_var)) / sqrt(2.0_r8 * PI)

prod_weight_right =  2.71828_r8 ** (-0.5_r8 * (ens(e_ind(ens_size))**2 / prior_var_d2 + &
      obs**2 / obs_var - new_mean_right**2 / new_var)) / sqrt(2.0_r8 * PI)

! Split into 2*ens_size domains; mass in each is computed
! Start by computing mass in the outermost (gaussian) regions
mass(1) = norm_cdf(ens(e_ind(1)), new_mean_left, new_sd) * &
   prod_weight_left * (2.0_r8 / (ens_size + 1.0_r8))
mass(2*ens_size) = (1.0_r8 - norm_cdf(ens(e_ind(ens_size)), new_mean_right, &
   new_sd)) * prod_weight_right * (2.0_r8 / (ens_size + 1.0_r8))

! Compute mass in the inner half boxes that have ensemble point on the left
do i = 2, 2*ens_size - 2, 2
   mass(i) = (1.0_r8 / (2.0_r8 * (ens_size + 1.0_r8))) * weight(e_ind(i/2))
end do

! Now right inner half boxes
do i = 3, 2*ens_size - 1, 2
   mass(i) = (1.0_r8 / (2.0_r8 * (ens_size + 1.0_r8))) * weight(e_ind(i/2 + 1))
end do

! Now normalize the mass in the different bins
mass_sum = sum(mass)
mass = mass / mass_sum

! Find cumulative mass at each box boundary and middle boundary
cumul_mass(0) = 0.0_r8
do i = 1, 2*ens_size
   cumul_mass(i) = cumul_mass(i - 1) + mass(i)
end do

! Get resampled ensemble, Need 1/(ens_size + 1) between each
umass = 1.0_r8 / (ens_size + 1.0_r8)

! Begin search at bottom of lowest box, but then update for efficiency
lowest_box = 1

! Find each new ensemble members location
do i = 1, ens_size
   ! If it's in the inner or outer range have to use normal
   if(umass < cumul_mass(1)) then
      ! In the first normal box
      left_weight = (1.0_r8 / mass_sum) * prod_weight_left * (2.0_r8 / (ens_size + 1.0_r8))
      call weighted_norm_inv(left_weight, new_mean_left, new_sd, umass, new_ens(i))
   else if(umass > cumul_mass(2*ens_size - 1)) then
      ! In the last normal box; Come in from the outside
      right_weight = (1.0_r8 / mass_sum) * prod_weight_right * (2.0_r8 / (ens_size + 1.0_r8))
      call weighted_norm_inv(right_weight, new_mean_right, new_sd, 1.0_r8 - umass, new_ens(i))
      new_ens(i) = new_mean_right + (new_mean_right - new_ens(i))
   else
      ! In one of the inner uniform boxes.
      FIND_BOX:do j = lowest_box, 2 * ens_size - 2
         ! Find the box that this mass is in
         if(umass >= cumul_mass(j) .and. umass <= cumul_mass(j + 1)) then
            new_ens(i) = x(j) + ((umass - cumul_mass(j)) / (cumul_mass(j+1) - cumul_mass(j))) * &
               (x(j + 1) - x(j))
            ! Don't need to search lower boxes again
            lowest_box = j
            exit FIND_BOX
         end if
      end do FIND_BOX
   endif
   ! Want equally partitioned mass in update with exception that outermost boxes have half
   umass = umass + 1.0_r8 / (ens_size + 1.0_r8)
end do

! Can now compute sorted increments
do i = 1, ens_size
   sort_inc(i) = new_ens(i) - ens(e_ind(i))
end do

! Now, need to convert to increments for unsorted
do i = 1, ens_size
   obs_inc(e_ind(i)) = sort_inc(i)
end do

end subroutine obs_increment_boxcar



subroutine obs_increment_rank_histogram(ens, ens_size, prior_var, &
   obs, obs_var, obs_inc)
!------------------------------------------------------------------------
! 
! Revised 14 November 2008
!
! Does observation space update by approximating the prior distribution by
! a rank histogram. Prior and posterior are assumed to have 1/(n+1) probability
! mass between each ensemble member. The tails are assumed to be gaussian with
! a variance equal to sample variance of the entire ensemble and a mean 
! selected so that 1/(n+1) of the mass is in each tail.
!
! The likelihood between the extreme ensemble members is approximated by
! quadrature. Two options are available and controlled by the namelist entry
! rectangular_quadrature. If this namelist is true than the likelihood between
! a pair of ensemble members is assumed to be uniform with the average of
! the likelihood computed at the two ensemble members. If it is false then
! the likelihood between two ensemble members is approximated by a line
! connecting the values of the likelihood computed at each of the ensemble
! members (trapezoidal quadrature). 
!
! Two options are available for approximating the likelihood on the tails.
! If gaussian_likelihood_tails is true that the likelihood is assumed to
! be N(obs, obs_var) on the tails. If this is false, then the likelihood
! on the tails is taken to be uniform (to infinity) with the value at the
! outermost ensemble members.
!
! A product of the approximate prior and approximate posterior is taken
! and new ensemble members are located so that 1/(n+1) of the mass is between
! each member and on the tails.

! This code is still under development. Please contact Jeff Anderson at
! jla@ucar.edu if you are interested in trying it. 

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

integer  :: i, e_ind(ens_size), lowest_box, j
real(r8) :: prior_sd, var_ratio, umass, left_amp, right_amp
real(r8) :: left_sd, left_var, right_sd, right_var, left_mean, right_mean
real(r8) :: mass(ens_size + 1), like(ens_size), cumul_mass(0:ens_size + 1)
real(r8) :: nmass(ens_size + 1)
real(r8) :: new_mean_left, new_mean_right, prod_weight_left, prod_weight_right
real(r8) :: new_var_left, new_var_right, new_sd_left, new_sd_right
real(r8) :: new_ens(ens_size), mass_sum
real(r8) :: x(ens_size)
real(r8) :: like_dense(2:ens_size), height(2:ens_size)
real(r8) :: dist_for_unit_sd
real(r8) :: a, b, c, hright, hleft, r1, r2, adj_r1, adj_r2

! Do an index sort of the ensemble members; Will want to do this very efficiently
call index_sort(ens, e_ind, ens_size)

do i = 1, ens_size
   ! The boundaries of the interior bins are just the sorted ensemble members
   x(i) = ens(e_ind(i))
   ! Compute likelihood for each ensemble member; just evaluate the gaussian
   ! No need to compute the constant term since relative likelihood is what matters
   like(i) = exp(-1.0_r8 * (x(i) - obs)**2 / (2.0_r8 * obs_var))
end do

! Prior distribution is boxcar in the central bins with 1/(n+1) density
! in each intermediate bin. BUT, distribution on the tails is a normal with
! 1/(n + 1) of the mass on each side.

! Can now compute the mean likelihood density in each interior bin
do i = 2, ens_size
   like_dense(i) = ((like(i - 1) + like(i)) / 2.0_r8)
end do

! Compute the s.d. of the ensemble for getting the gaussian tails
prior_sd = sqrt(prior_var)

! For unit normal, find distance from mean to where cdf is 1/(n+1)
! Lots of this can be done once in first call and then saved
call weighted_norm_inv(1.0_r8, 0.0_r8, 1.0_r8, &
   1.0_r8 / (ens_size + 1.0_r8), dist_for_unit_sd)
dist_for_unit_sd = -1.0_r8 * dist_for_unit_sd

! Have variance of tails just be sample prior variance
! Mean is adjusted so that 1/(n+1) is outside
left_mean = x(1) + dist_for_unit_sd * prior_sd
left_var = prior_var
left_sd = prior_sd
! Same for right tail
right_mean = x(ens_size) - dist_for_unit_sd * prior_sd
right_var = prior_var
right_sd = prior_sd

if(gaussian_likelihood_tails) then
   !*************** Block to do Gaussian-Gaussian on tail **************
   ! Compute the product of the obs likelihood gaussian with the priors 
   ! Left tail gaussian first
   var_ratio = obs_var / (left_var + obs_var)
   new_var_left = var_ratio * left_var
   new_sd_left = sqrt(new_var_left)
   new_mean_left  = var_ratio * (left_mean  + left_var*obs / obs_var)
   ! REMEMBER, this product has an associated weight which must be taken into account
   ! See Anderson and Anderson for this weight term (or tutorial kernel filter)
   ! NOTE: The constant term has been left off the likelihood so we don't have
   ! to divide by sqrt(2 PI) in this expression
   prod_weight_left =  exp(-0.5_r8 * (left_mean**2 / left_var + &
         obs**2 / obs_var - new_mean_left**2 / new_var_left)) / &
         sqrt(left_var + obs_var)
   ! Determine how much mass is in the updated tails by computing gaussian cdf
   mass(1) = norm_cdf(x(1), new_mean_left, new_sd_left) * prod_weight_left

   ! Same for the right tail
   var_ratio = obs_var / (right_var + obs_var)
   new_var_right = var_ratio * right_var
   new_sd_right = sqrt(new_var_right)
   new_mean_right  = var_ratio * (right_mean  + right_var*obs / obs_var)
   ! NOTE: The constant term has been left off the likelihood so we don't have
   ! to divide by sqrt(2 PI) in this expression
   prod_weight_right =  exp(-0.5_r8 * (right_mean**2 / right_var + &
         obs**2 / obs_var - new_mean_right**2 / new_var_right)) / &
         sqrt(right_var + obs_var)
   ! Determine how much mass is in the updated tails by computing gaussian cdf
   mass(ens_size + 1) = (1.0_r8 - norm_cdf(x(ens_size), new_mean_right, &
      new_sd_right)) * prod_weight_right
   !************ End Block to do Gaussian-Gaussian on tail **************
else
   !*************** Block to do flat tail for likelihood ****************
   ! Flat tails: THIS REMOVES ASSUMPTIONS ABOUT LIKELIHOOD AND CUTS COST
   new_var_left = left_var
   new_sd_left = left_sd
   new_mean_left = left_mean
   prod_weight_left = like(1)
   mass(1) = like(1) / (ens_size + 1.0_r8) 

   ! Same for right tail
   new_var_right = right_var
   new_sd_right = right_sd
   new_mean_right = right_mean
   prod_weight_right = like(ens_size)
   mass(ens_size + 1) = like(ens_size) / (ens_size + 1.0_r8)
   !*************** End block to do flat tail for likelihood ****************
endif

! The mass in each interior box is the height times the width
! The height of the likelihood is like_dense
! For the prior, mass is 1/(n+1),   and mass = height x width so...
! The height of the prior is 1 / ((n+1) width);   multiplying by width leaves 1/(n+1)

! In prior, have 1/(n+1) mass in each bin, multiply by mean likelihood density
! to get approximate mass in updated bin 
do i = 2, ens_size
   mass(i) = like_dense(i) / (ens_size + 1.0_r8)
   ! Height of prior in this bin is mass/width; Only needed for trapezoidal
   ! If two ensemble members are the same, set height to -1 as flag
   if(x(i) == x(i - 1)) then 
      height(i) = -1.0_r8
   else
      height(i) = 1.0_r8 / ((ens_size + 1.0_r8) * (x(i) - x(i-1)))
   endif
end do

! Now normalize the mass in the different bins to get a pdf
mass_sum = sum(mass)
nmass = mass / mass_sum

! Get the weight for the final normalized tail gaussians
! This is the same as left_amp=(ens_size + 1)*nmass(1)
left_amp = prod_weight_left / mass_sum
! This is the same as right_amp=(ens_size + 1)*nmass(ens_size + 1)
right_amp = prod_weight_right / mass_sum

! Find cumulative mass at each box boundary and middle boundary
cumul_mass(0) = 0.0_r8
do i = 1, ens_size + 1
   cumul_mass(i) = cumul_mass(i - 1) + nmass(i)
end do

! Begin intenal box search at bottom of lowest box, update for efficiency
lowest_box = 1

! Find each new ensemble members location
do i = 1, ens_size
   ! Each update ensemble member has 1/(n+1) mass before it
   umass = (1.0_r8 * i) / (ens_size + 1.0_r8)

   ! If it is in the inner or outer range have to use normal
   if(umass < cumul_mass(1)) then
      ! It's in the left tail
      ! Get position of x in weighted gaussian where the cdf has value umass
      call weighted_norm_inv(left_amp, new_mean_left, new_sd_left, &
         umass, new_ens(i))
   else if(umass > cumul_mass(ens_size)) then
      ! It's in the right tail
      ! Get position of x in weighted gaussian where the cdf has value umass
      call weighted_norm_inv(right_amp, new_mean_right, new_sd_right, &
         1.0_r8 - umass, new_ens(i))
      ! Coming in from the right, use symmetry after pretending its on left
      new_ens(i) = new_mean_right + (new_mean_right - new_ens(i))
   else
      ! In one of the inner uniform boxes.
      FIND_BOX:do j = lowest_box, ens_size - 1
         ! Find the box that this mass is in
         if(umass >= cumul_mass(j) .and. umass <= cumul_mass(j + 1)) then

            if(rectangular_quadrature) then
               !********* Block for rectangular quadrature *******************
               ! Linearly interpolate in mass
               new_ens(i) = x(j) + ((umass - cumul_mass(j)) / &
                  (cumul_mass(j+1) - cumul_mass(j))) * (x(j + 1) - x(j))
               !********* End block for rectangular quadrature *******************

            else

               !********* Block for trapezoidal interpolation *******************
               ! Assume that mass has linear profile, quadratic interpolation
               ! If two ensemble members are the same, just keep that value
               if(height(j + 1) < 0) then
                  new_ens(i) = x(j)
               else
                  ! Height on left side and right side
                  hleft = height(j + 1) * like(j) / mass_sum
                  hright = height(j + 1) * like(j + 1) / mass_sum
                  ! Will solve a quadratic for desired x-x(j)
                  ! a is 0.5(hright - hleft) / (x(j+1) - x(j))
                  a = 0.5_r8 * (hright - hleft) / (x(j+1) - x(j))
                  ! b is hleft
                  b = hleft
                  ! c is cumul_mass(j) - umass
                  c = cumul_mass(j) - umass
                  ! Use stable quadratic solver
                  call solve_quadratic(a, b, c, r1, r2)
                  adj_r1 = r1 + x(j)
                  adj_r2 = r2 + x(j)
                  if(adj_r1 >= x(j) .and. adj_r1 <= x(j+1)) then
                     new_ens(i) = adj_r1
                  elseif (adj_r2 >= x(j) .and. adj_r2 <= x(j+1)) then
                     new_ens(i) = adj_r2
                  else
                     msgstring = 'Did not get a satisfactory quadratic root' 
                     call error_handler(E_ERR, 'obs_increment_rank_histogram', msgstring, &
                        source, revision, revdate)
                  endif
               endif
               !********* End block for quadratic interpolation *******************
            
            endif

            ! Don't need to search lower boxes again
            lowest_box = j
            exit FIND_BOX
         end if
      end do FIND_BOX
   endif
end do

! Convert to increments for unsorted
do i = 1, ens_size
   obs_inc(e_ind(i)) = new_ens(i) - x(i)
end do

end subroutine obs_increment_rank_histogram




subroutine update_ens_from_weights(ens, ens_size, rel_weight, ens_inc)
!------------------------------------------------------------------------
! Given relative weights for an ensemble, compute increments for the
! ensemble members. Assumes that prior distributon is equal uniform mass
! between each ensemble member. On the edges, have a normal with the
! sample mean and s.d. BUT normalized by a factor alpha so that only
! 1/(2*ens_size) of the total mass lies on each flank.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), rel_weight(ens_size)
real(r8), intent(out) :: ens_inc(ens_size)

integer  :: i, j, lowest_box
integer  :: e_ind(ens_size)
real(r8) :: x(1:2*ens_size - 1), cumul_mass(1:2*ens_size - 1), new_ens(ens_size)
real(r8) :: sort_inc(ens_size), updated_mass(2 * ens_size)
real(r8) :: sx, prior_mean, prior_var, prior_sd, mass
real(r8) :: total_mass_left, total_mass_right, alpha(2)

! Initialize assim_tools_module if needed
if (.not. module_initialized) call assim_tools_init()

call error_handler(E_ERR,'update_ens_from_weight','Routine needs testing.', &
           source, revision, revdate, text2='Talk to Jeff before using.')

! Do an index sort of the ensemble members
call index_sort(ens, e_ind, ens_size)

! Have half boxes between all ensembles in the interior
! Total number of mass boxes is 2*ens_size

! Compute the points that bound all the updated mass boxes; start with ensemble
do i = 1, ens_size
   x(2*i - 1) = ens(e_ind(i))
end do
! Compute the mid-point interior boundaries; these are halfway between ensembles
do i = 2, 2*ens_size - 2, 2
   x(i) = (x(i - 1) + x(i + 1)) / 2.0_r8
end do

! Compute the mean and s.d. of the prior ensemble to handle wings
sx         = sum(ens)
prior_mean = sx / ens_size
prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)
prior_sd = sqrt(prior_var)

! Need to normalize the wings so they have 1/(2*ens_size) mass outside
! Use cdf to find out how much mass is left of 1st member, right of last
total_mass_left = norm_cdf(ens(e_ind(1)), prior_mean, prior_sd)
total_mass_right = 1.0_r8 - norm_cdf(ens(e_ind(ens_size)), prior_mean, prior_sd)

! Find the mass in each division given the initial equal partition and the weights
updated_mass(1) = rel_weight(e_ind(1)) / (2.0_r8 * ens_size)
updated_mass(2 * ens_size) = rel_weight(e_ind(ens_size)) / (2.0_r8 * ens_size)
do i = 2, 2*ens_size - 2, 2
   updated_mass(i) = rel_weight(e_ind(i / 2)) / (2.0_r8 * ens_size)
end do
do i = 3, 2*ens_size - 1, 2
   updated_mass(i) = rel_weight(e_ind((i+1) / 2)) / (2.0_r8 * ens_size)
end do

! Normalize the mass; (COULD IT EVER BE 0 necessitating error check?)
updated_mass = updated_mass / sum(updated_mass)

! Find a normalization factor to get tail mass right
if(total_mass_left > 0.0_r8) then
   alpha(1) = updated_mass(1) / total_mass_left
else
   alpha(1) = 0.0_r8
endif
if(total_mass_right > 0.0_r8) then
   alpha(2) = updated_mass(2 * ens_size) / total_mass_right
else
   alpha(2) = 0.0_r8
endif

! Find cumulative mass at each box boundary and middle boundary
cumul_mass(1) = updated_mass(1)
do i = 2, 2*ens_size - 1
   cumul_mass(i) = cumul_mass(i - 1) + updated_mass(i)
end do

! Get resampled position an inefficient way
! Need 1/ens_size between each EXCEPT for outers which get half of this
mass = 1.0_r8 / (2.0_r8 * ens_size)

do i = 1, ens_size
   ! If it's in the inner or outer range have to use normal
   if(mass < cumul_mass(1)) then
      ! In the first normal box
      call weighted_norm_inv(alpha(1), prior_mean, prior_sd, mass, new_ens(i))
   else if(mass > cumul_mass(2*ens_size - 1)) then
      ! In the last normal box; Come in from the outside
      call weighted_norm_inv(alpha(2), prior_mean, prior_sd, 1.0_r8 - mass, new_ens(i))
      new_ens(i) = prior_mean + (prior_mean - new_ens(i))
   else
      ! In one of the inner uniform boxes. Make this much more efficient search?
      lowest_box = 1
      FIND_BOX:do j = lowest_box, 2 * ens_size - 2
         ! Find the box that this mass is in
         if(mass >= cumul_mass(j) .and. mass <= cumul_mass(j + 1)) then
            new_ens(i) = x(j) + ((mass - cumul_mass(j)) / (cumul_mass(j+1) - cumul_mass(j))) * &
               (x(j + 1) - x(j))
            ! Don't need to search lower boxes again
            lowest_box = j
            exit FIND_BOX
         end if
      end do FIND_BOX
   endif
   ! Want equally partitioned mass in update with exception that outermost boxes have half
   mass = mass + 1.0_r8 / ens_size
end do

! Can now compute sorted increments
do i = 1, ens_size
   sort_inc(i) = new_ens(i) - ens(e_ind(i))
end do

! Now, need to convert to increments for unsorted
do i = 1, ens_size
   ens_inc(e_ind(i)) = sort_inc(i)
end do

end subroutine update_ens_from_weights


!------------------------------------------------------------------------

function norm_cdf(x_in, mean, sd)

! Approximate cumulative distribution function for normal
! with mean and sd evaluated at point x_in
! Only works for x>= 0.

real(r8)             :: norm_cdf
real(r8), intent(in) :: x_in, mean, sd

real(digits12) :: x, p, b1, b2, b3, b4, b5, t, density, nx

! Convert to a standard normal
nx = (x_in - mean) / sd

x = abs(nx) 


! Use formula from Abramowitz and Stegun to approximate
p = 0.2316419_digits12
b1 = 0.319381530_digits12
b2 = -0.356563782_digits12
b3 = 1.781477937_digits12
b4 = -1.821255978_digits12
b5 = 1.330274429_digits12

t = 1.0_digits12 / (1.0_digits12 + p * x)

density = (1.0_digits12 / sqrt(2.0_digits12 * PI)) * exp(-x*x / 2.0_digits12)

norm_cdf = 1.0_digits12 - density * &
   ((((b5 * t + b4) * t + b3) * t + b2) * t + b1) * t

if(nx < 0.0_digits12) norm_cdf = 1.0_digits12 - norm_cdf

!write(*, *) 'cdf is ', norm_cdf

end function norm_cdf


!------------------------------------------------------------------------

subroutine weighted_norm_inv(alpha, mean, sd, p, x)

! Find the value of x for which the cdf of a N(mean, sd) multiplied times
! alpha has value p.

real(r8), intent(in)  :: alpha, mean, sd, p
real(r8), intent(out) :: x

real(r8) :: np

! Can search in a standard normal, then multiply by sd at end and add mean
! Divide p by alpha to get the right place for weighted normal
np = p / alpha

! Find spot in standard normal
call norm_inv(np, x)

! Add in the mean and normalize by sd
x = mean + x * sd

end subroutine weighted_norm_inv


!------------------------------------------------------------------------

subroutine norm_inv(p, x)

real(r8), intent(in)  :: p
real(r8), intent(out) :: x

! normal inverse
! translate from http://home.online.no/~pjacklam/notes/invnorm
! a routine written by john herrero

real(r8) :: p_low,p_high
real(r8) :: a1,a2,a3,a4,a5,a6
real(r8) :: b1,b2,b3,b4,b5
real(r8) :: c1,c2,c3,c4,c5,c6
real(r8) :: d1,d2,d3,d4
real(r8) :: q,r
a1 = -39.69683028665376_digits12
a2 =  220.9460984245205_digits12
a3 = -275.9285104469687_digits12
a4 =  138.357751867269_digits12
a5 = -30.66479806614716_digits12
a6 =  2.506628277459239_digits12
b1 = -54.4760987982241_digits12
b2 =  161.5858368580409_digits12
b3 = -155.6989798598866_digits12
b4 =  66.80131188771972_digits12
b5 = -13.28068155288572_digits12
c1 = -0.007784894002430293_digits12
c2 = -0.3223964580411365_digits12
c3 = -2.400758277161838_digits12
c4 = -2.549732539343734_digits12
c5 =  4.374664141464968_digits12
c6 =  2.938163982698783_digits12
d1 =  0.007784695709041462_digits12
d2 =  0.3224671290700398_digits12
d3 =  2.445134137142996_digits12
d4 =  3.754408661907416_digits12
p_low  = 0.02425_digits12
p_high = 1_digits12 - p_low
! Split into an inner and two outer regions which have separate fits
if(p < p_low) then
   q = sqrt(-2.0_digits12 * log(p))
   x = (((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6) / &
      ((((d1*q + d2)*q + d3)*q + d4)*q + 1.0_digits12)
else if(p > p_high) then
   q = sqrt(-2.0_digits12 * log(1.0_digits12 - p))
   x = -(((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6) / &
      ((((d1*q + d2)*q + d3)*q + d4)*q + 1.0_digits12)
else 
   q = p - 0.5_digits12
   r = q*q
   x = (((((a1*r + a2)*r + a3)*r + a4)*r + a5)*r + a6)*q / &
      (((((b1*r + b2)*r + b3)*r + b4)*r + b5)*r + 1.0_digits12)
endif

end subroutine norm_inv

!------------------------------------------------------------------------

subroutine set_assim_tools_trace(execution_level, timestamp_level)
 integer, intent(in) :: execution_level
 integer, intent(in) :: timestamp_level

! set module local vars from the calling code to indicate how much
! output we should generate from this code.  execution level is
! intended to make it easier to figure out where in the code a crash
! is happening; timestamp level is intended to help with gross levels
! of overall performance profiling.  eventually, a level of 1 will
! print out only basic info; level 2 will be more detailed.
! (right now, only > 0 prints anything and it doesn't matter how
! large the value is.)

! Initialize assim_tools_module if needed
if (.not. module_initialized) call assim_tools_init()

print_trace_details = execution_level
print_timestamps    = timestamp_level

end subroutine set_assim_tools_trace

!------------------------------------------------------------------------

function get_missing_ok_status()
 logical :: get_missing_ok_status

! see if the namelist variable allows missing values in the
! model state or not.

! Initialize assim_tools_module if needed
if (.not. module_initialized) call assim_tools_init()

get_missing_ok_status = allow_missing_in_clm

end function get_missing_ok_status

!--------------------------------------------------------------------

function revised_distance(orig_dist, newcount, oldcount, base, cutfloor)
 real(r8),            intent(in) :: orig_dist
 integer,             intent(in) :: newcount, oldcount
 type(location_type), intent(in) :: base
 real(r8),            intent(in) :: cutfloor

 real(r8)                        :: revised_distance
 
! take the ratio of the old and new counts, and revise the
! original cutoff distance to match.

! for now, only allow the code to do a 2d area adaption.
! to experiment with other schemes, set this local variable
! to .false. at the top of the file and recompile.

if (only_area_adapt) then

   revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

   ! allow user to set a minimum cutoff, so even if there are very dense
   ! observations the cutoff distance won't go below this floor.
   if (revised_distance < cutfloor) revised_distance = cutfloor
   return

endif

! alternatives for different dimensionalities and schemes

! Change the cutoff radius to get the appropriate number 
if (LocationDims == 1) then
   ! linear (be careful of cyclic domains; if > domain, this is
   ! not going to be right)
   revised_distance = orig_dist * real(newcount, r8) / oldcount

else if (LocationDims == 2) then
   ! do an area scaling
   revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

else if (LocationDims == 3) then
   ! do either a volume or area scaling (depending on whether we are
   ! localizing in the vertical or not.)   if surface obs, assume a hemisphere
   ! and shrink more.

   if (vertical_localization_on()) then
      ! cube root for volume
      revised_distance = orig_dist * ((real(newcount, r8) / oldcount) &
                                      ** 0.33333333333333333333_r8)

      ! Cut the adaptive localization threshold in half again for 'surface' obs
      if (is_vertical(base, "SURFACE")) then
         revised_distance = revised_distance * (0.5_r8 ** 0.33333333333333333333_r8)
      endif
   else
      ! do an area scaling, even if 3d obs
      revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

      ! original code was:
      !cutoff_rev =  sqrt((2.0_r8*cutoff)**2 * adaptive_localization_threshold / &
      !   total_num_close_obs) / 2.0_r8

      ! original comment
      ! Need to get thinning out of assim_tools and into something about locations
   endif
else
   call error_handler(E_ERR, 'revised_distance', 'unknown locations dimension, not 1, 2 or 3', &
      source, revision, revdate)
endif

! allow user to set a minimum cutoff, so even if there are very dense
! observations the cutoff distance won't go below this floor.
if (revised_distance < cutfloor) revised_distance = cutfloor

end function revised_distance

!--------------------------------------------------------------------

function count_close(num_close, index_list, my_types, dist, maxdist)
 integer, intent(in)  :: num_close, index_list(:), my_types(:)
 real(r8), intent(in) :: dist(:), maxdist
 integer :: count_close

! return the total number of items from the index_list which
! are types which are going to be assimilated, and within distance.
! this excludes items on the eval list only, not listed, or
! items too far away.   this routine does a global communication
! so if any MPI tasks make this call, all must.

integer :: k, thistype, local_count

local_count = 0
do k=1, num_close

   ! only accept items closer than limit
   if (dist(k) > maxdist) cycle

   ! include identity obs, plus types on assim list.
   ! you have to do the if tests separately because fortran allows
   ! both parts of an if(a .or. b) test to be eval'd at the same time.
   ! you'd be using a negative index if it was an identity obs.
   thistype = my_types(index_list(k))
   if (thistype < 0) then
      local_count = local_count + 1
   else if (assimilate_this_type_of_obs(thistype)) then
      local_count = local_count + 1
   endif
end do

! broadcast sums from all tasks to compute new total
call sum_across_tasks(local_count, count_close)

end function count_close

! bpd6
function count_ranks_with_close(num_close, index_list, my_types, dist, maxdist)
 integer, intent(in)  :: num_close, index_list(:), my_types(:)
 real(r8), intent(in) :: dist(:), maxdist
 integer :: count_ranks_with_close

! return the total number of items from the index_list which
! are types which are going to be assimilated, and within distance.
! this excludes items on the eval list only, not listed, or
! items too far away.   this routine does a global communication
! so if any MPI tasks make this call, all must.

integer :: k, thistype, local_count

local_count = 0
do k=1, num_close

   ! only accept items closer than limit
   if (dist(k) > maxdist) cycle

   ! include identity obs, plus types on assim list.
   ! you have to do the if tests separately because fortran allows
   ! both parts of an if(a .or. b) test to be eval'd at the same time.
   ! you'd be using a negative index if it was an identity obs.
   thistype = my_types(index_list(k))
   if (thistype < 0) then
      local_count = 1
   else if (assimilate_this_type_of_obs(thistype)) then
      local_count = 1
   endif
end do

! broadcast sums from all tasks to compute new total
call sum_across_tasks(local_count, count_ranks_with_close)

end function count_ranks_with_close

subroutine write_obdata(obdata_unit, i, num_close_states, skipped_missing, skipped_covfactor, stateupdate_time)
  use mpi
  implicit none
  integer, intent(in) :: obdata_unit, i
  integer, intent(in) ::  num_close_states, skipped_missing, skipped_covfactor
  real(r8), intent(in) :: stateupdate_time

  integer :: k
  integer :: mpiRank, mpiSize, iError
  integer :: num_close_states_total, skipped_missing_total, skipped_covfactor_total
  integer :: num_close_obs_total
  integer :: statesupdated, statesupdated_total
  real(r8) :: stateupdate_time_total

  ! Just gonna hard-code some arrays for now - max 16K ranks:
  integer, parameter :: arraysize = 16384
  integer, dimension(arraysize) :: state_updates_per_rank
  integer, dimension(arraysize) :: cov_skips_per_rank
  real(r8), dimension(arraysize) :: time_per_rank

  integer :: cov_flag = 0
  integer :: cov_flag_total = 0

  call MPI_Comm_Rank(MPI_COMM_WORLD, mpiRank, iError)
  call MPI_Comm_Size(MPI_COMM_WORLD, mpiSize, iError)

  ! reduce to get totals:
  call MPI_Reduce(num_close_states, num_close_states_total, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
  call MPI_Reduce(skipped_missing,  skipped_missing_total,  1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
  call MPI_Reduce(skipped_covfactor,  skipped_covfactor_total,  1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)
  call MPI_Reduce(stateupdate_time,  stateupdate_time_total,  1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, iError)

  ! Gather 

  ! We want several different entries per ob, and can 'grep' out what we want:
  ! 1) State update info : ob, #ranks doing state updates, total #states updated, (ranks) state updates per rank
  ! 2) COV skip info     : ob, #ranks where cov factor eliminates updates, total # of cov-skipped states, (ranks) cov-skips per rank
  ! 3) update timing info: ob, #ranks doing state updates, total #states updated, (ranks) timing for this update
  statesupdated = num_close_states - skipped_missing - skipped_covfactor
  call MPI_Gather(statesupdated, 1, MPI_INTEGER, state_updates_per_rank, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, iError)
  call MPI_Gather(stateupdate_time, 1, MPI_DOUBLE_PRECISION, time_per_rank, 1, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, iError)


  cov_flag = 0
  if (num_close_states == skipped_covfactor) then
     if (num_close_states /= 0) then
        cov_flag = 1
     endif
  endif

  call MPI_Reduce(cov_flag, cov_flag_total, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, iError)




  ! Get some tallies:
  statesupdated_total = num_close_states_total - skipped_missing_total - skipped_covfactor_total

  ! State updates:
  if (mpiRank == 0) then
    !write(obdata_unit, '(A,I,A,I,A,I)', advance="no") "StateUpdateInfo: ", i, " ", count(state_updates_per_rank/=0), " ", statesupdated_total
    !do k = 1, mpiSize
    !  write(obdata_unit, '(A,I)', advance="no") " ", state_updates_per_rank(k)
    !enddo 
    !write(obdata_unit,'(A)'), " " 
  endif

  ! COV skip:
  if (mpiRank == 0) then
    if (cov_flag_total /= 0) then
         write(*,*) "*** DEBUG *** cov_flag_total = ", cov_flag_total
    endif
    !write(obdata_unit, '(A,I,A,I)', advance="no") "COV Skip Info: ", i, " ", skipped_covfactor_total
    !do k = 1, mpiSize
    !  write(obdata_unit, '(A,I)', advance="no") " ", state_updates_per_rank(k)
    !enddo 
    !write(obdata_unit,'(A)'), " " 
  endif

  ! Timing info:
  if (mpiRank == 0) then
    !write(obdata_unit, '(A,I,A,I,A,I)', advance="no") "TimingInfo: ", i, " ", count(state_updates_per_rank/=0), " ", statesupdated_total
    !do k = 1, mpiSize
    !  write(obdata_unit, '(A,F)', advance="no") " ", time_per_rank(k)
    !enddo 
    !write(obdata_unit,'(A)'), " " 
  endif


end subroutine write_obdata

subroutine write_obdata2(obdata_unit2, i)
  implicit none
  integer, intent(in) :: obdata_unit2, i

  integer, save :: unitnum = -1

  if (unitnum == -1) then
    unitnum = obdata_unit2
  else
    !write(unitnum, '(A)') ""
  endif

  !write(unitnum, '(I)', advance="no") i
end subroutine write_obdata2

subroutine append_obdata2(obdata_unit2, j)
  implicit none
  integer, intent(in) :: obdata_unit2, j

  !write(obdata_unit2, '(A,I)', advance="no") ",", j
end subroutine append_obdata2


!bpd6
subroutine list_close(obs_id, fileunit, total, num_close, index_list, my_types, dist, maxdist)
 integer, intent(in) :: obs_id, fileunit, total
 integer, intent(in)  :: num_close, index_list(:), my_types(:)
 real(r8), intent(in) :: dist(:), maxdist

 integer :: k, thistype, fullcount, local_count
 integer, dimension(:), allocatable :: list

 ! get the full count of close obs
 ! fullcount = count_close(num_close, index_list, my_types, dist, maxdist)

 ! allocate an array of that size:
 !allocate(list(fullcount))

  !write(fileunit,'(I,A,I,A)',advance="no")  obs_id, " ", total, " "
!  write(fileunit,'(I,A)',advance="no")   total, ", "

 ! Loop over 
do k=1, num_close

! Debug
!write(*,'(A,I,A,I,A,I,A,I,A,F,A,F)') "List Trace -> Ob: ",obs_id,"  Close: ",k," of ",num_close,"  ID: ", index_list(k), " Dist: ",dist(k), " > ",maxdist

   ! only accept items closer than limit
   if (dist(k) > maxdist) cycle

   ! include identity obs, plus types on assim list.
   ! you have to do the if tests separately because fortran allows
   ! both parts of an if(a .or. b) test to be eval'd at the same time.
   ! you'd be using a negative index if it was an identity obs.
   thistype = my_types(index_list(k))
   if (thistype < 0) then
      !write(fileunit, '(I,A)',advance="no") index_list(k), " "
      !!local_count = local_count + 1
   else if (assimilate_this_type_of_obs(thistype)) then
      !write(fileunit, '(I,A)',advance="no") index_list(k), " "
      !!local_count = local_count + 1
   endif
end do

  !write(fileunit,'(A)') ""

end subroutine list_close

subroutine list_close_state(i, list_unit, num_close_states, close_state_ind)
 integer, intent(in) :: i, list_unit, num_close_states
 integer, intent(in) :: close_state_ind(:)

 integer :: k

 do k = 1, num_close_states
   !write(list_unit, '(I,A)', advance="no") close_state_ind(k), " "
end do
  !write(list_unit,'(A)') ""

end subroutine list_close_state


!----------------------------------------------------------------------
!> gets the location of of all my observations
subroutine get_my_obs_loc(state_ens_handle, obs_ens_handle, obs_seq, keys, my_obs_loc, my_obs_kind, my_obs_type, my_obs_time)

type(ensemble_type),      intent(in)  :: state_ens_handle
type(ensemble_type),      intent(in)  :: obs_ens_handle
type(obs_sequence_type),  intent(in)  :: obs_seq
integer,                  intent(in)  :: keys(:)
type(location_type),      intent(out) :: my_obs_loc(:)
integer,                  intent(out) :: my_obs_type(:), my_obs_kind(:)
type(time_type),          intent(out) :: my_obs_time

type(obs_type) :: observation
type(obs_def_type)   :: obs_def
integer :: this_obs_key
integer i
type(location_type) :: dummyloc

Get_Obs_Locations: do i = 1, obs_ens_handle%my_num_vars

   this_obs_key = keys(obs_ens_handle%my_vars(i)) ! if keys becomes a local array, this will need changing
   call get_obs_from_key(obs_seq, this_obs_key, observation)
   call get_obs_def(observation, obs_def)
   my_obs_loc(i)  = get_obs_def_location(obs_def)
   my_obs_type(i) = get_obs_def_type_of_obs(obs_def)
   if (my_obs_type(i) > 0) then
         my_obs_kind(i) = get_quantity_for_type_of_obs(my_obs_type(i))
   else
      call get_state_meta_data(-1 * int(my_obs_type(i),i8), dummyloc, my_obs_kind(i))
   endif
end do Get_Obs_Locations

! Need the time for regression diagnostics potentially; get from first observation
my_obs_time = get_obs_def_time(obs_def)

end subroutine get_my_obs_loc

!--------------------------------------------------------------------
!> log what the user has selected via the namelist choices

subroutine log_namelist_selections(num_special_cutoff, cache_override)

integer, intent(in) :: num_special_cutoff
logical, intent(in) :: cache_override

integer :: i

select case (filter_kind)
 case (1)
   msgstring = 'Ensemble Adjustment Kalman Filter (EAKF)'
 case (2)
   msgstring = 'Ensemble Kalman Filter (ENKF)'
 case (3)
   msgstring = 'Kernel filter'
 case (4)
   msgstring = 'observation space particle filter'
 case (5)
   msgstring = 'random draw from posterior'
 case (6)
   msgstring = 'deterministic draw from posterior with fixed kurtosis'
 case (7)
   msgstring = 'Boxcar'
 case (8)
   msgstring = 'Rank Histogram Filter'
 case default 
   call error_handler(E_ERR, 'assim_tools_init:', 'illegal filter_kind value, valid values are 1-8', &
                      source, revision, revdate)
end select
call error_handler(E_MSG, 'assim_tools_init:', 'Selected filter type is '//trim(msgstring))

if (adjust_obs_impact) then
   call allocate_impact_table(obs_impact_table)
   call read_impact_table(obs_impact_filename, obs_impact_table, allow_any_impact_values)
   call error_handler(E_MSG, 'assim_tools_init:', &
                      'Using observation impact table from file "'//trim(obs_impact_filename)//'"')
endif

write(msgstring,  '(A,F18.6)') 'The cutoff namelist value is ', cutoff
write(msgstring2, '(A)') 'cutoff is the localization half-width parameter,'
write(msgstring3, '(A,F18.6)') 'so the effective localization radius is ', cutoff*2.0_r8
call error_handler(E_MSG,'assim_tools_init:', msgstring, text2=msgstring2, text3=msgstring3)

if (has_special_cutoffs) then
   call error_handler(E_MSG, '', '')
   call error_handler(E_MSG,'assim_tools_init:','Observations with special localization treatment:')
   call error_handler(E_MSG,'assim_tools_init:','(type name, specified cutoff distance, effective localization radius)') 

   do i = 1, num_special_cutoff
      write(msgstring, '(A32,F18.6,F18.6)') special_localization_obs_types(i), &
            special_localization_cutoffs(i), special_localization_cutoffs(i)*2.0_r8                     
      call error_handler(E_MSG,'assim_tools_init:', msgstring)
   end do
   call error_handler(E_MSG,'assim_tools_init:','all other observation types will use the default cutoff distance')
   call error_handler(E_MSG, '', '')
endif

if (cache_override) then
   call error_handler(E_MSG,'assim_tools_init:','Disabling the close obs caching because specialized localization')
   call error_handler(E_MSG,'assim_tools_init:','distances are enabled. ')
endif

if(adaptive_localization_threshold > 0) then
   write(msgstring, '(A,I10,A)') 'Using adaptive localization, threshold ', &
                                  adaptive_localization_threshold, ' obs'
   call error_handler(E_MSG,'assim_tools_init:', msgstring)
   if(adaptive_cutoff_floor > 0.0_r8) then
      write(msgstring, '(A,F18.6)') 'Minimum cutoff will not go below ', &
                                     adaptive_cutoff_floor
      call error_handler(E_MSG,'assim_tools_init:', 'Using adaptive localization cutoff floor.', &
                         text2=msgstring)
   endif
endif

if(output_localization_diagnostics) then
   call error_handler(E_MSG,'assim_tools_init:', 'Writing localization diagnostics to file:')
   call error_handler(E_MSG,'assim_tools_init:', trim(localization_diagnostics_file))
endif

if(sampling_error_correction) then
   call error_handler(E_MSG,'assim_tools_init:', 'Using Sampling Error Correction')
endif

if (task_count() > 1) then
    if(distribute_mean) then
       msgstring  = 'Distributing one copy of the ensemble mean across all tasks'
       msgstring2 = 'uses less memory per task but may run slower if doing vertical '
    else
       msgstring  = 'Replicating a copy of the ensemble mean on every task'
       msgstring2 = 'uses more memory per task but may run faster if doing vertical '
    endif
    call error_handler(E_MSG,'assim_tools_init:', msgstring, text2=msgstring2, &
                       text3='coordinate conversion; controlled by namelist item "distribute_mean"')
endif

if (has_vertical_choice()) then
   if (.not. vertical_localization_on()) then
      msgstring = 'Not doing vertical localization, no vertical coordinate conversion required'
      call error_handler(E_MSG,'assim_tools_init:', msgstring)
   else
      msgstring = 'Doing vertical localization, vertical coordinate conversion may be required'
      if (convert_all_state_verticals_first) then
         msgstring2 = 'Converting all state vector verticals to localization coordinate first.'
      else
         msgstring2 = 'Converting all state vector verticals only as needed.'
      endif
      if (convert_all_obs_verticals_first) then
         msgstring3 = 'Converting all observation verticals to localization coordinate first.'
      else
         msgstring3 = 'Converting all observation verticals only as needed.'
      endif
      call error_handler(E_MSG,'assim_tools_init:', msgstring, text2=msgstring2, text3=msgstring3)
   endif
endif

end subroutine log_namelist_selections

!===========================================================
! TEST FUNCTIONS BELOW THIS POINT
!-----------------------------------------------------------
!> test get_state_meta_data
!> Write out the resutls of get_state_meta_data for each task
!> They should be the same as the Trunk version
subroutine test_get_state_meta_data(locations, num_vars)

type(location_type), intent(in) :: locations(:)
integer,             intent(in) :: num_vars

character*20  :: task_str !< string to hold the task number
character*129 :: file_meta !< output file name
character(len=128) :: locinfo
integer :: i

write(task_str, '(i10)') my_task_id()
file_meta = TRIM('test_get_state_meta_data' // TRIM(ADJUSTL(task_str)))

open(15, file=file_meta, status = 'unknown')

do i = 1, num_vars
   call write_location(-1, locations(i), charstring=locinfo)
   write(15,*) trim(locinfo)
enddo

close(15)


end subroutine test_get_state_meta_data

!--------------------------------------------------------
!> dump out the copies array for the state ens handle
subroutine test_state_copies(state_ens_handle, information)

type(ensemble_type), intent(in) :: state_ens_handle
character(len=*),        intent(in) :: information

character*20  :: task_str !< string to hold the task number
character*129 :: file_copies !< output file name
integer :: i

write(task_str, '(i10)') state_ens_handle%my_pe
file_copies = TRIM('statecopies_'  // TRIM(ADJUSTL(information)) // '.' // TRIM(ADJUSTL(task_str)))
open(15, file=file_copies, status ='unknown')

do i = 1, state_ens_handle%num_copies - state_ens_handle%num_extras
   write(15, *) state_ens_handle%copies(i,:)
enddo

close(15)

end subroutine test_state_copies

!--------------------------------------------------------
!> dump out the distances calculated in get_close_obs
subroutine test_close_obs_dist(distances, num_close, ob)

real(r8), intent(in) :: distances(:) !< array of distances calculated in get_close
integer,  intent(in) :: num_close !< number of close obs
integer,  intent(in) :: ob

character*20  :: task_str !< string to hold the task number
character*20  :: ob_str !< string to hold ob number
character*129 :: file_dist !< output file name
integer :: i

write(task_str, '(i10)') my_task_id()
write(ob_str, '(i20)') ob
file_dist = TRIM('distances'   // TRIM(ADJUSTL(task_str)) // '.' // TRIM(ADJUSTL(ob_str)))
open(15, file=file_dist, status ='unknown')

write(15, *) num_close

do i = 1, num_close
   write(15, *) distances(i)
enddo

close(15)

end subroutine test_close_obs_dist

!> @}

!========================================================================
! end module assim_tools_mod
!========================================================================

end module assim_graph_tools_mod

! <next few lines under version control, do not edit>
! $URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/assimilation_code/modules/assimilation/assim_tools_mod.f90 $
! $Id: assim_tools_mod.f90 11799 2017-07-07 21:08:09Z nancy@ucar.edu $
! $Revision: 11799 $
! $Date: 2017-07-07 15:08:09 -0600 (Fri, 07 Jul 2017) $