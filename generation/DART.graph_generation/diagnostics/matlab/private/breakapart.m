function x = breakapart(mystring)
%% breakapart  breaks a character string into a cell array of words
%
% Example:
% mystring = 'This has several words 1.234';
% x = breakapart(mystring)
% x =
%
%    'This'    'has'    'several'    'words'    '1.234'
%

%% DART software - Copyright UCAR. This open source software is provided
% by UCAR, "as is", without charge, subject to all terms of use at
% http://www.image.ucar.edu/DAReS/DART/DART_download
%
% DART $Id: breakapart.m 11626 2017-05-11 17:27:50Z nancy@ucar.edu $

x{1} = [];
i    = 1;

while true

   [str, mystring] = strtok(mystring,' ');
   if isempty(str), break; end
   x{i} = str;
   i = i + 1;

end


% <next few lines under version control, do not edit>
% $URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/diagnostics/matlab/private/breakapart.m $
% $Revision: 11626 $
% $Date: 2017-05-11 11:27:50 -0600 (Thu, 11 May 2017) $
