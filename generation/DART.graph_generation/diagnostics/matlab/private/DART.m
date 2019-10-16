%% DART - the list of routines useful for exploring the output of the DART
%        ensemble assimilation software. This is not intended to be an exhaustive
%        list, but it should get you started. -- Tim
%
% DART/matlab			These functions explore the [Truth,] Prior,Posterior netCDF
%                               files. Useful for "state-space" diagnostics.
% plot_bins.m                   rank histograms
% plot_correl.m			space-time series of correlation
% plot_ens_err_spread.m		summary plots of the ensemble error and ensemble spread
% plot_ens_mean_time_series.m	time series of ensemble mean and truth
% plot_ens_time_series.m	time series of ensemble members, mean and truth
% plot_phase_space.m		trajectory of 3 state variables of a single ensemble member
% plot_sawtooth.m		time series of a state variable including updates
% plot_smoother_err.m		global error and spread using the smoother
% plot_total_err.m		plots of global error and spread of ensemble mean
% plot_var_var_correl.m		correlation of a vrbl at a time and another vrbl at all times
%
%
% DART/diagnostics/matlab	This block requires that the observation sequences in
%                               question have been run through "obs_diag" and have
%                               resulted in "obs_diag_output.nc" files. Strictly
%                               "observation-space" diagnostics. Typical quantities of
%                               interest are : rmse, bias, spread, totalspread, ...
% plot_observation_locations.m	locations of observations, by QC value
% plot_profile.m		vertical profile of a single quantity
% plot_bias_xxx_profile.m	vertical profile of the bias and any other quantity
% plot_rmse_xxx_profile.m 	vertical profile of the rmse and any other quantity
% plot_evolution.m		temporal evolution of any quantity
% plot_rmse_xxx_evolution.m	temporal evolution of the rmse and one other quantity
% plot_wind_vectors.m		This is a "one-off" ... since DART actually only knows
%                               about univariate observations, matching them into pairs
%                               is perilous ...
%
%
% DART/diagnostics/matlab	These functions require processing
%                               observation sequences into netCDF files with
%                               "obs_seq_to_netcdf" - which currently does not preserve
%                               all of the observation sequence metadata for some of the
%                               more complicated observation types.
% read_obs_netcdf.m		Reads a netCDF observation sequence and returns a structure.
% plot_obs_netcdf.m		creates a 2D or 3D plot of the observation locations
%                               and values - and rejected observations.
% plot_obs_netcdf_diffs.m	ditto, only for the difference of two observation copies
%                               - the observation and the ensemble mean, for example.
%
%
% DART/models/<modelname>/matlab	Each model has an optional matlab directory where
%                               the model developers are free to supply whatever functions
%                               or scripts they deem useful.

%% DART software - Copyright UCAR. This open source software is provided
% by UCAR, "as is", without charge, subject to all terms of use at
% http://www.image.ucar.edu/DAReS/DART/DART_download
%
% DART $Id: DART.m 11289 2017-03-10 21:56:06Z hendric@ucar.edu $

% <next few lines under version control, do not edit>
% $URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/diagnostics/matlab/private/DART.m $
% $Revision: 11289 $
% $Date: 2017-03-10 14:56:06 -0700 (Fri, 10 Mar 2017) $
