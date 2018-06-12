% Author: Danie Ludick (dludick@sun.ac.za)
% Project: PEC plate example
%
% Note: Each project directory / example directory needs to have a sunem_initialise.m
% script, that is used to setup the correct environment for that example.
%
% Refer to the /doc folder for more information

% --------------------------------------------------------------------------------------------------
% Initialise the environment
% --------------------------------------------------------------------------------------------------
% Project output directory: './dipoles/'
% Debug: True/False
Const = sunem_initialise('pec_plate',false);

% --------------------------------------------------------------------------------------------------
% Program flow settings
% --------------------------------------------------------------------------------------------------

% Choose the solvers that will be executed
Const.runMoMsolver          = true;
Const.runCBFMsolver         = false;
Const.runJacobisolver       = false;
Const.runIFBMoMsolver       = false;

% --------------------------------------------------------------------------------------------------
% Define input files for extracting FEKO data
% --------------------------------------------------------------------------------------------------
Const.FEKOmatfilename          = 'pec_plate.mat';
Const.FEKOstrfilename          = 'pec_plate.str';
Const.FEKOrhsfilename          = 'pec_plate.rhs';
Const.FEKOoutfilename          = 'pec_plate.out';
Const.FEKOefefilename          = 'pec_plate.efe';
Const.FEKOffefilename          = 'pec_plate.ffe';

% --------------------------------------------------------------------------------------------------
% Define output files for transferring expansion coefficients back to FEKO data
% --------------------------------------------------------------------------------------------------
Const.SUNEMmomstrfilename      = 'sunem_mom_pec_plate.str';

% --------------------------------------------------------------------------------------------------
% Define additional program flow constants
% --------------------------------------------------------------------------------------------------
% TO-DO: Setup some documentation for this
Const.no_mutual_coupling_array = false; % Deactivate coupling between domains.
Const.calcSecMBFs = false;      % For MBF based solvers
Const.useMBFreduction = true;   % SVD applied after the MBFs are generated to retain an orthonormal set
Const.MBFthreshold = 1000;      % Threshold used for the SVD reduction of the MBFs
Const.IFBalg = 14;              % Jacobi iterations (7). Adaptive MBF (14).
Const.IFB_iterations = 10;      % Number of Jacobi iterations. (TO-DO: Ellaborate special meaning, e.g. -1)
                                % which then looks at Const.IFB_convergence_threshold_percentage;
Const.IFB_convergence_threshold_percentage = 1E-3;                                
Const.IFB_CBFs = -1;            % TO-DO: Recheck this - essentially for the Adaptive MBF the number of MBFs
                                % to use during each iteration
Const.IFB_debug = 1;
Const.cache_Z0_V0 = false;      % Precompute the Z0 and V0 terms
Const.use_DGFM_start = false;   % Use the DGFM to calculate the initial (0th) solution


% --------------------------------------------------------------------------------------------------
% Read the MoM matrix equation from the file
% --------------------------------------------------------------------------------------------------
[Const, zMatricesFEKO, yVectorsFEKO, xVectorsFEKO] = extractFEKOMoMmatrixEq(Const);

% --------------------------------------------------------------------------------------------------
% Parse the setup files to extract the frequency sweep, the geometry and basis function setup 
% --------------------------------------------------------------------------------------------------
% TO-DO: At a later stage we can also add other meshing / geometry
% preprocessxing, e.g. Gmsh or GiD. For now the solver setup is read from FEKO.
[Const, Solver_setup] = parseFEKOoutfile(Const, yVectorsFEKO);

% 2018.06.10: If we are going to run the SUNEM MoM solver, then we need to extract our own internal
% MoM matrix equation. Note: we can only do this after the solver data (i.e. geometry, etc. is setup)
[Const, zMatricesSUNEM, yVectorsSUNEM] = extractSUNEMMoMmatrixEq(Const, Solver_setup);

% DJdbg --> remove
%Z = zMatricesSUNEM.values;
Z = zMatricesFEKO.values;

fprintf("Z(%d,%d) = %.5f + %.5f\n", 1,1,real(Z(1,1)), imag(Z(1,1)));
fprintf("Z(%d,%d) = %.5f + %.5f\n", 1,26,real(Z(1,26)), imag(Z(1,26)));
fprintf("Z(%d,%d) = %.5f + %.5f\n", 1,4,real(Z(1,4)), imag(Z(1,4)));

error('wag hier');

% Compare now the above with that calculated using FEKO
compareMatrices(Const,zMatricesSUNEM.values, zMatricesFEKO.values);

% For the RHS vectors, we calculate the rel. error norm % (2-norm)
yVectorErr = calculateErrorNormPercentage(yVectorsFEKO.values, yVectorsSUNEM.values);
message_fc(Const,sprintf('Rel. error norm. for V(RHS) compared to FEKO sol. %f percent',yVectorErr));

error('wag hier');

% --------------------------------------------------------------------------------------------------
% Run the EM solver 
% --------------------------------------------------------------------------------------------------
% (Note: We either pass our own (internal) matrices, or those read from FEKO)
[Solution] = runEMsolvers(Const, Solver_setup, zMatricesSUNEM, yVectorsSUNEM, xVectorsFEKO);

% --------------------------------------------------------------------------------------------------
% Postprocess the results, e.g. calculate the Electric field
% --------------------------------------------------------------------------------------------------
if (false)

    r = 100;%100;
    % Loop over a few theta and phi points and compare the results with that of FEKO
    theta_grid = 90:1:90;
    phi_grid = 0:1:90;

    num_theta_samples = length(theta_grid);
    num_phi_samples = length(phi_grid);
    total_efield_samples = num_theta_samples*num_phi_samples;
    Efield_magnitude = zeros(total_efield_samples,1);

    % Read the FEKO data from a *.efe file for comparison
    FEKO_EfieldAtPoint = parseFEKOefefile(Const, Const.FEKOefefilename);
    FEKO_total_efield_samples = FEKO_EfieldAtPoint.number_r_samples * ...
        FEKO_EfieldAtPoint.number_theta_samples * FEKO_EfieldAtPoint.number_phi_samples;
    FEKO_Efield_magnitude = sqrt(abs(r.*FEKO_EfieldAtPoint.Er).^2 + ...
        abs(r.*FEKO_EfieldAtPoint.Etheta).^2 + ...
        abs(r.*FEKO_EfieldAtPoint.Ephi).^2);

    % Read also now FEKO's far field values here.
    FEKO_farfield = parseFEKOffefile(Const, Const.FEKOffefilename);
    FEKO_total_farfield_samples =  FEKO_farfield.number_theta_samples * FEKO_farfield.number_phi_samples;
    FEKO_farfield_magnitude = sqrt(abs(FEKO_farfield.Etheta).^2 + abs(FEKO_farfield.Ephi).^2);

    % Calculate now the E-field value here internal
    index = 0;
    for theta_degrees = theta_grid
        for phi_degrees = phi_grid % 0 to 90 degr. in steps of 1 degrees
            index = index + 1;

            % Uncomment below for additional debug output
            %fprintf(sprintf('Calculating now the E-field at: (r,theta,phi) = (%2.f,%2.f,%2.f)\n',r,theta_degrees,phi_degrees));

            % Calculate the Electric field in spherical co-ordinates
            EfieldAtPointSpherical =  calculateEfieldAtPointRWG(Const, r, theta_degrees, phi_degrees, ...
                Solver_setup, Solution.mom.Isol);

            % Calculate now the magnitude of the E-field vector. 
            % Note: Change the unit of the E-field now fom V/m to V by 
            % multiplying with the distance [r], at which
            % the E-field was calculated.
            Efield_magnitude(index) = sqrt(abs(r.*EfieldAtPointSpherical(1))^2 + ...
                abs(r.*EfieldAtPointSpherical(2))^2 + ...
                abs(r.*EfieldAtPointSpherical(3))^2);
        end%for
    end%for

    % Plot now the total E-field grid
    figure;
    hold on;
    grid on;

    % Plot the normalised values
    plot_normalised_field = false;
    if (plot_normalised_field)
        max_Efield_magnitude = max(Efield_magnitude);
        max_FEKO_Efield_magnitude = max(FEKO_Efield_magnitude);
        max_FEKO_farfield_magnitude = max(FEKO_farfield_magnitude);
    else
        % No normalisation applied, i.e. set the factor to 1.
        max_Efield_magnitude = 1.0;
        max_FEKO_Efield_magnitude = 1.0;
        max_FEKO_farfield_magnitude = 1.0;
    end%if

    plot(1:total_efield_samples,Efield_magnitude./max_Efield_magnitude,'LineWidth',3);
    plot(1:FEKO_total_efield_samples,FEKO_Efield_magnitude./max_FEKO_Efield_magnitude,'x','LineWidth',3);
    plot(1:FEKO_total_farfield_samples,FEKO_farfield_magnitude./max_FEKO_farfield_magnitude,'o','LineWidth',3);
    legend('SUN-EM','FEKO (*.efe file)', 'FEKO (*.ffe file)');
    set(get(gca, 'XLabel'), 'String', ('Sample index'));
    set(get(gca, 'YLabel'), 'String', ('|E-field| [V]'));

    % There is a constant offset here. Try and figure out why we have this. Ideally, this should be around 1.
    % The following code was just required to extract the 2*pi constant that our code differs from FEKO
    % for the near-field calculation. Uncomment again if observing a large difference in the field values.
    % figure;
    % hold on;
    % grid on;
    % Efield_scaling_factor = Efield_magnitude./FEKO_Efield_magnitude;
    % plot(1:total_efield_samples,Efield_scaling_factor);

end%if