function [params,RF2,U2] = runAbaqusVerification ... 
               (bestpos, bestval, tests, testnums, need_analysis, save_xls)
% Provide your PSO results, and this function will return the "actual"
% (non-transformed) Armstrong-Frederick Parameters. Additionally, it will
% run an ABAQUS job with those parameters, and plot out the results so that
% you may visually inspect them.
%
%
% bestpos   = transformed output from PSO algorithm
% bestval   = output from PSO algorithm (for informational purposes only)
% tests     = specifically designed .mat struct file containing test data
%             (see documentation)
% testnums  = subset of tests on which to run analysis, or string 'all'
% need_analysis = boolean indicating whether abaqus runs need to be
%                 submitted (default = True). Otherwise it assumes you
%                 already have run the analyses, and only want some plots.
% save_xls  = boolean indicating whether you want to save the
%             force-displacement information into an excel spreadsheet
%             (default = False)

%
% Add Calibration path to search directory, so those functions can be used.
%
calib_dir = strrep(pwd, 'Verification', 'Calibration');
if ( exist(calib_dir,'dir') == 7 )
    addpath(calib_dir);
else
    addpath('..');
end

%
% ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
% Recover Parameters from bestpos
%

% check if bestpos comes from normalized PSO, or is actual AF params
% (this is a disgusting hack)
if mod(length(bestpos),2) == 0
    % length bestpos is even, meaning it is a normalized PSO param vector
    
    %bestpos(1)       = Fy
    %bestpos(2)       = total hardening
    %bestpos(3)       = C0 (linear kinematic term)
    %bestpos(4)       = b (isotropic rate term)
    %bestpos(5,7,...) = gamman (nth kinematic rate)
    %bestpos(6,8,...) = fraction saturated hardening per ksi backstress

    Fy = bestpos(1);
    C0 = bestpos(3);
    b  = bestpos(4);

    totalksi=0;
    for n = 1:( (length(bestpos) - 4)/2 )
        %extract params, keeping track of total ksi for Qinf
        gamman(n) = bestpos(2*n+3); %#ok<*AGROW>
        Cn(n)     = bestpos(2) * bestpos(2*n+4) * gamman(n);
        totalksi  = totalksi + bestpos(2) * bestpos(2*n+4);
    end
    % set Qinf
    Qinf = bestpos(2) - totalksi;

    % define params
    params = [Fy Qinf b C0 0 reshape([Cn;gamman],length(Cn)*2,1)'];

else
    % length bestpos is odd, meaning it is already set to be AF params
    params = bestpos;
    
    % in almost all cases, this is not what the user wants.
    fprintf('\n')
    fprintf(2, ['runAbaqusVerification :: Input is inconsistent with ', ...
                'normalized PSO parameters... \n',                      ...
                'instead, assuming they are pre-defined AF parameters.']);
	fprintf('\n')
end
 
% save params
save('AF_parameters.mat','params')

%
% ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
% check inputs
%

% get all field names of the .mat struct
testnames = fieldnames(tests);

% check the requested inputs...
if (nargin < 4) || strcmpi(testnums,'all')
    % run all tests if not otherwise specified, or if 'all' specified
    testnums = 1:length(testnames);
end

if nargin < 5
    % default is to submit ABAQUS jobs
    need_analysis = true;
end

if nargin < 6
    % default is to not save an excel spreadsheet
    save_xls = false;
end

% obtain the relevant test names
testnames = testnames(testnums);
num_tests = length(testnames);

% check that the testnames struct's contain all required fields
checkRequiredUserInputs(tests, testnames)

%
% ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
% run the simulations
%
if need_analysis
    % display information for user
    fprintf('Writing INP Histories...');

    % using a template input file, insert our own *Static and *Amplitude
    % keyword settings, based on test displacement peaks (hist)
    for i = 1:num_tests
        % addHistINPfile(template, target, testdata)
        writeHistINPfile( tests.(testnames{i}).template, ... 
                          [testnames{i} '.inp'], tests.(testnames{i}) );
    end
    fprintf(' Done!\n');

    % copy the input file generated by addHistINPfile
    % write constituitive params to this copy
    fprintf('Writing INP Parameters...');
    for i = 1:num_tests
        % writeParamsINPfile(basefile, newfile, params)
        writeParamsINPfile( testnames{i}, [testnames{i} '-dum'], params );
    end
    fprintf(' Done!\n');

    % run all requested jobs
    msghandle = msgbox('Running Abaqus Jobs...');
    runAbaqusJobs(strcat(testnames, '-dum'), 5);

    % clean up msgbox
    if ishandle(msghandle)
        close(msghandle);
    end

end

%
% ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
% compare the displacement curves for each test/simulation
%
figs = cell(1,num_tests);
fprintf('Comparing displacement curves... ');
for i = 1:num_tests
    
    %
    % get the real data and test info
	%
    
    % set job's .ODB name (also the name of the .INP file)
    fileID    = [testnames{i} '-dum'];
    
    % set the name of the assembly-level reaction node set
    rxNodeSet = tests.(testnames{i}).rxNodeSet;
    
    % set the "real" test data
    if tests.(testnames{i}).symmetric
        % if the simulation is symmetric, divide displ by 2
        realdata = [tests.(testnames{i}).displ/2, tests.(testnames{i}).force];
    else
        % otherwise, use full displ
        realdata = [tests.(testnames{i}).displ, tests.(testnames{i}).force];
    end
    
    %
	% obtain force-displacement data from Abaqus
    %
    
    [~, RF2{i}, U2{i}] = fetchOdbLoadDispl(fileID, rxNodeSet);
    
    %
    % plot into figure to compare, for each individual test
    %
    
    %open new figure
    figs{i} = figure;
    
    %plot abaqus data
	plot( U2{i}, RF2{i}, 'g' )
    hold on
    
    % plot real test data
    plot(realdata(:,1), realdata(:,2));
    
    % give it a meaningful title
    title_ = sprintf(' %s\n combined error = %s', ...
                     testnames{i}, num2str(bestval));
    title(title_);
    
    % give it a meaningful legend
    legend('ABAQUS','Test', 'Location','best');
    
    % save plot to disk
    saveas(figs{i},testnames{i},'pdf')
    saveas(figs{i},testnames{i},'png')
    
    % if requested, save force-displacement data to excel spreadsheet
    if save_xls
        xlswrite('ForceDispl.xls',{'Displ','Force'},testnames{i},'A1:B1');
        xlswrite('ForceDispl.xls',U2{i},testnames{i},'A2');
        xlswrite('ForceDispl.xls',RF2{i},testnames{i},'B2');
    end
end
fprintf('Done!');

return;
end