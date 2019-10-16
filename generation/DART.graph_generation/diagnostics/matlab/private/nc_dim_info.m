function [dimlen, dimid] = nc_dim_info(fname,dimname)
%% nc_dim_info Tests to see if the dimension exists in a netCDF file - without throwing an error.
% If the dimension exists, returns a 1, if it does not exist, it returns a 0
% Optionally returns the Matlab 'native' variable id ...
%
%
% EXAMPLE 1  ... dimension not present, dimlen is []
% fname = 'obs_diag_output.nc';
% dimname = 'no_dimension_by_this_name';
% dimlen = nc_dim_info(fname,dimname)
%
% EXAMPLE 2  ... dimension present, only want the dimension length
% fname = 'obs_diag_output.nc';
% dimname = 'region';
% dimlen = nc_dim_info(fname,dimname)
%
% EXAMPLE 3  ... dimension present, want dimension length and dimension ID
% fname = 'obs_diag_output.nc';
% dimname = 'time';
% [dimlen, dimid] = nc_dim_info(fname,dimname)

%% DART software - Copyright UCAR. This open source software is provided
% by UCAR, "as is", without charge, subject to all terms of use at
% http://www.image.ucar.edu/DAReS/DART/DART_download
%
% DART $Id: nc_dim_info.m 11626 2017-05-11 17:27:50Z nancy@ucar.edu $

dimlen = [];
dimid  = [];

finfo  = ncinfo(fname);

for idim = 1:length(finfo.Dimensions)
   if (strcmp(finfo.Dimensions(idim).Name, deblank(dimname)))
      dimid  = idim;
      dimlen = finfo.Dimensions(idim).Length;
      return
   end
end

% <next few lines under version control, do not edit>
% $URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/diagnostics/matlab/private/nc_dim_info.m $
% $Revision: 11626 $
% $Date: 2017-05-11 11:27:50 -0600 (Thu, 11 May 2017) $
