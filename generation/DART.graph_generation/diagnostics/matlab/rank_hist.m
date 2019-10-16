function bins = rank_hist(ens, verif)
%% RANK_HIST: private function to compute a rank histogram given time series of ensemble and verification
%
% The function to create and plot the rank histogram is called "plot_bins".
%
% Example
%
% truth_file = 'true_state.nc';
% diagn_file = 'preassim.nc';
% plot_bins

%% DART software - Copyright UCAR. This open source software is provided
% by UCAR, "as is", without charge, subject to all terms of use at
% http://www.image.ucar.edu/DAReS/DART/DART_download
%
% DART $Id: rank_hist.m 11626 2017-05-11 17:27:50Z nancy@ucar.edu $

[ens_size, num_times] = size(ens);

% If one of the dimensions of 'ens' is unity - it must be time.
% If that happens, transpose these things. Why can't Matlab just
% leave the dimensions alone! There has already been a check to make
% sure the ensemble size is greater than 2, so it cannot be 1 here.

if (ens_size == 1)
    ens = ens';
    num_times = size(ens,1);
    ens_size  = size(ens,2);
end

% Need ens_size + 1 bins
bins(1:ens_size + 1) = 0.0;

% Loop through time series to get count for each bin
for itime = 1:num_times
   count = 0;
   for imem = 1:ens_size
      if verif(itime) > ens(imem,itime)
         count = count + 1;
      end
   end
   bins(count+1) = bins(count+1) + 1;
end

% <next few lines under version control, do not edit>
% $URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/diagnostics/matlab/rank_hist.m $
% $Revision: 11626 $
% $Date: 2017-05-11 11:27:50 -0600 (Thu, 11 May 2017) $
