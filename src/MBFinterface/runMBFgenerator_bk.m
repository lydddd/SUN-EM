function [mbfs] = runMBFgenerator(Const, Solver_setup, zMatrices, yVectors, xVectors)
    %runMBFgenerator
    %   Date: 30.11.2013
    %   Usage:
    %       [mbfs] = runMBFgenerator(Const, zMatrices, yVectors, xVectors)
    %
    %   Input Arguments:
    %       Const
    %           A global struct, containing general data
    %       Solver_setup
    %           Solver specific struct, e.g. frequency range, basis function details, geometry details    
    %       zMatrices
    %           The Z-matrices data
    %       yVectors
    %           The Yrhs-vector data
    %       xVectors
    %           The Xsol-vector data (i.e. MoM solution of FEKO)
    %   Output Arguments:
    %       dgfm
    %           Structs containing MBFs (pimary and possibly secondaries) and timing data
    %
    %   Description:
    %       Calculates primary and secondary MBFs
    %        - Primary MBFs are generated as Jprim = (Zself)^(-1) * Vself
    %        - Secondary MBFs are generated as Jsec = (Zself)^(-1) * Zcoupl * Jprim
    %          where Zself and Zcoupl are the self-interaction and coupling matrices
    %          between two domains P and Q. Vself is the excitation vector entries
    %          local to the domain P. 
    %
    %   TO-DO: 
    %        - The Const.secMBFcouplingrad variable, specifies the coupling radius that is 
    %          used to specify which elements should be included for secondary CBFs. Currently, 
    %          all elements are included. The FEKO geometry should then be read also from the 
    %          *.out file. - logged in FEKDDM-3.4
    %        - The ACA can also be used here to accelerate the matrix vector product involved 
    %          with the secondary MBF generation - logged in FEKDDM-3.2
    %        - Parallelisation of the solver - logged in FEKDDM-3.3
    %
    %   Assumptions:
    %        - All domains are the same size (i.e. contains the same number of unknowns)
    %
    %   References:
    %   [1] V. V. S. Prakash and Raj Mittra, "Characteristic Basis Function Method: 
    %       A New Technique for Efficient Solution of Method of Moments Matrix Equations," 
    %       in Microwave and Optical Technology Letters, Vol. 36, No. 2
    %       Jan, 2003, pp. 95-100.
    %
    %   =======================
    %   Written by Danie Ludick on June 24, 2013.    
    %   Stellenbosch University
    %   Email: dludick@sun.ac.za
    %
    % Notes:
    %       See issue FEKDDM-3.5 (and FEKDDM-10): Multiple RHS vectors are now supported
    
    narginchk(5,5);
    
    message_fc(Const,' ');
    message_fc(Const,'------------------------------------------------------------------------------------');
    message_fc(Const,sprintf('Running MBF generator'));
    if (Const.no_mutual_coupling_array)
        message_fc(Const,sprintf('(*** Mutual coupling between array elements ignored ***)'));
        message_fc(Const,sprintf('Discarding mutual coupling - not correctly implemented for CBFM'));
        error(['Discarding mutual coupling - not correctly implemented for CBFM']);
    end%if
        
    % Initialise the return values
    mbfs  = [];
    Nmom        = Solver_setup.num_mom_basis_functions;    % Total number of basis functions for whole problem
    Nngf        = Solver_setup.num_ngf_basis_functions;    % Number of basis functions for NGF domain

    % 2017.06.03: We need to work on the max number of basis functions (BFs) per element here (as we might have
    % interconnected) arrays that have different number of BFs / element.
    %Ndom        = Solver_setup.max_mom_basis_functions_per_array_element;   % Number of basis functions per array element        
    numArrayEls = Solver_setup.num_finite_array_elements;  % The number of array elements
    numGeneratingSubarrays = Solver_setup.generating_subarrays.number_of_domains; % Number of generating sub-arrays,
                                                                                  % for connected structures
    numSols     = xVectors.numSols;             % The number of solutions configurations

    % If we are reducing and orthonormalising the MBFs by using the SVD,
    % then store these in a differents array than mbfs.PrimIsol and
    % mbfs.SecIsol
    if (Const.useMBFreduction)
        % Note, we are unsure at this stage how many reduced MBFs we will
        % retain. Just allocated enough space here (numArrayEls should do
        % the trick). Note: Might have to be increased also if the number of generating sub-arrays
        % is large). (Perhaps simplest just to allocate 2*numArrayEls)
        % 2018.06.04: Increase now the size of RedIsol to the global MoM size (not per domain any more).
        mbfs.RedIsol = complex(zeros(Nmom,numArrayEls,numArrayEls,numSols));
        mbfs.numRedMBFs = zeros(numArrayEls,numSols); % Number of Red. MBFs / array element / solution config.
    end%if
        
    % See FEKDDM-3.1: Store the primary CBFs also in the same structure as
    % the secondary CBFs.
    % Structure to be followed:   (MBF{1:Ndom},PrimIndx,DomainInd)
    % NOTE: The PrimIndx is to account for the port excitation on the element, i.e. each port results 
    % in one primary MBF
    % See issue FEKDDM-3.5 (and FEKDDM-10), multiple solution
    % configurations are now supported (i.e. for multiple RHS vectors only).
    % Extend the structure for storing primary and secondary MBFs as follows:
    % Structure to be followed:   (MBF{1:Ndom},PrimIndx,DomainInd,solNum)
    % See FEKDDM-3.7: The following has to be changed to account for
    % multiple primary MBFs (as would be the case for multiple ports per
    % base domain) - then change the second dimension.
    % 2018.06.04: Increase now the size of PrimIsol to the global MoM size (not per domain any more).
    % 2018.06.07: The number of primaries / domain will not be 1 when we have interconnected domains
    % with generating sub-arrays (radiating case).
    max_primaries_per_domain = 1;
    if (~Solver_setup.disconnected_domains)
        % Number of primaries / domain - in the case of generating sub-arrays will depend on the location
        % of the element in the array. As a maximum, just take the maximum number of domains in any 
        % generating sub-array configuration. Loop over all sub-arrays and extract the max domain size
        max_subarray_domains = 0;
        for ii = 1:numGeneratingSubarrays
            max_subarray_domains = max(max_subarray_domains, ...
                length(Solver_setup.generating_subarrays.domains{ii}));            
        end%for ii=1:Solver_setup.generating_subarrays.number_of_domains
        max_primaries_per_domain = max_subarray_domains;
    end%if

    mbfs.PrimIsol = complex(zeros(Nmom,max_primaries_per_domain,numArrayEls,numSols));

    % The above solution should be bug enough, but we still have to keep track of the actual number
    % of MBFs
    mbfs.numPrimMBFs = zeros(numArrayEls,numSols); % Number of Prim. MBFs / solution config.
    mbfs.numSecMBFs = zeros(numArrayEls,numSols);  % Number of Sec.  MBFs / solution config.
    if (Const.calcSecMBFs)
        % TO-DO: Adjust the second dimension of the secondary CBFs according
        % to the number that will be included - here, all neighbouring elements 
        % are accounted for (i.e. numArrayEls - 1 secondary MBFs will be
        % induced) - see also FEKDDDM-2 for additional features that are planned
        %                           (Ndom,  SecIndx    ,  DomainInd)
        % See issue FEKDDM-3.5 (and FEKDDM-10): Added now support for
        % multiple solution configurations. Threfore extend the structure
        % as follows:               (Ndom,  SecIndx    ,  DomainInd, # Sol. Configurations)
        % 2018.06.04: Increase now the size of SecIsol to the global MoM size (not per domain any more).
        % 2018.06.07: For connected arrays, we follow the same reasoning as above - i.e. the number of 
        % secondaries depend on the number of primaries that again depend on the number of generating sub-arrays.
        mbfs.SecIsol = complex(zeros(Nmom,max_primaries_per_domain*(numArrayEls-1),numArrayEls,numSols));        
    end%if
    
    % 2018.06.03: We also support now interconnected domains. Only therefore 
    % pre-allocate certain MBF datastructures if we have a disjoint array problem.
    % Otherwise, these have to be calculated per domain.
    if (Solver_setup.disconnected_domains)

        % We are working with identical domains. Generate the LU decomposition
        % of the static interaction matrix of domain 1 beforehand and reuse
        % this in the following calculations
        % TO-DO: Danie, save this to the Temp directory and load it here to save time
        % See issue FEKDDM-6.2: Improved now the basis function numbering for
        % the array domain (work with bottom and top basis function offsets)
        % TO-DO: Assumed here are 1-to-1 mapping, i.e. Const.arrayMappingVector
        %        not yet used.        
        domain_indices = Solver_setup.rwg_basis_functions_domains{1}; % domain 1
        % TO-DO: Actually use the calcZmn function here with the correct frequency index.
        [L,U] = lu(zMatrices.values(domain_indices, domain_indices));
    end

    % See issue FEKDDM-10: We added now support for multiple solution configurations.
    % Each solution configuration get its own set of primary and secondary MBFs, 
    % depending on the solution excitation configuration.
    for solNum = 1:numSols
    
        % Start timing (per solution)
        tic
        
        % ======================================
        % Setup the primary MBFs
        % ======================================

        % 2018.06.07: The following has now been updated to accommodate also
        % generating sub-arrays for interconnected domains.
        if (~Solver_setup.disconnected_domains)
            num_sub_arrays = numGeneratingSubarrays;
        else
            % Disconnected domains - we have only 1 generating sub-array
            num_sub_arrays = 1;
        end
        
        % Generate the primary MBF: Jprim = (Zself)^(-1) * Vself
        mbfs.numPrimMBFs(:,solNum) = 0;
        
        for ii = 1:num_sub_arrays

            % 2018.06.07: Each of the sub-arrays have domains. If we are not working with a connected
            % array example, then the domains correspond to the number of array elements.

            if (~Solver_setup.disconnected_domains)
                % Extract the number of domains within this sub-array
                num_domains = length(Solver_setup.generating_subarrays.domains{ii});
            else
                % Disconnected domains - we have only 1 generating sub-array
                num_domains = numArrayEls;
            end

            % For each of the domains, we calculate primary MBFs
            for m=1:num_domains

                % Extract the correct domain index
                if (~Solver_setup.disconnected_domains)
                    % Extract domain index from sub-array list
                    domain_index = Solver_setup.generating_subarrays.domains{m};
                    % For interconnected domains, we need to extract the unknowns
                    % associated with the sub-arrays.
                    domain_basis_functions = Solver_setup.rwg_basis_functions_domains{m};
                else
                    % Disconnected domains - index just the same as m
                    domain_index = m;
                    % Note: if we have an interconnected domain problem, then this represents
                    % the extended domain's solution.
                    domain_basis_functions = Solver_setup.rwg_basis_functions_domains{m};
                end

                % We only generate a primary MBF if the array element is active. TO-DO: Not entirely sure
                % how this will correspond to the generating sub-array case.
                if (Const.is_array_element_active(domain_index,solNum))

                    % Now, if we have a generating sub-array, i.e. for connected domains, then we excite ONLY
                    % the current element.
                    yVectors_genPrim = complex(zeros(length(domain_basis_functions),1));
                    yVectors_genPrim = yVectors.values(domain_basis_functions,solNum);

                    % Back-wards substitution with the part of the excitation vector local to this domain.

                    % 2018.06.03: We also support now interconnected domains. Calculate
                    % the LU decomposition here for the particular domain (will not be
                    % the same for each element or generating sub-array).
                    if (~Solver_setup.disconnected_domains)
                        % TO-DO: Actually use the calcZmn function here with the correct frequency index.
                        [L,U] = lu(zMatrices.values(domain_basis_functions, domain_basis_functions));
                    end

                    mbfs.numPrimMBFs(m,solNum) = mbfs.numPrimMBFs(m,solNum) + 1;

                    b = L\yVectors_genPrim;

                    mbfs.PrimIsol(domain_basis_functions,1,m,solNum) = U\b; % U, already calculated above

                    % Before we continue, we need to window the primary MBF here, if we are working with interconnected
                    % domains:
                    if (~Solver_setup.disconnected_domains && true)
                        % -- Windowing  (only if we have interconnected domains)
                        
                        % Let's first determine the BFs on the interface esssentially the difference between the 
                        % unknowns internal to the domain and that on the interface.
                        interface_basis_functions = setdiff(domain_basis_functions, ...
                            Solver_setup.rwg_basis_functions_internal_domains{m});

                        % Apply now windowing : Factor of a half.
                        mbfs.PrimIsol(interface_basis_functions,1,m,solNum) = 0.5.*mbfs.PrimIsol(interface_basis_functions,1,m,solNum);
                    end%if
                end%if
            end%for

        end%for ii = 1:num_sub_arrays

        % TO-DO: After generating the MBFs on the particular sub-arrays (and windowing them appropriately), we need to
        %        apply them to the correct domains in the finite array.
        
        % End timing
        mbfs.primGenTime(solNum) = toc;
        
        % ======================================
        % Setup the secondary MBFs (if included)
        % ======================================
        if (Const.calcSecMBFs)
            
            tic % Start timing
            
            % Generate the secondary MBF: Jsec = (Zself)^(-1) * Zcoupl * Jprim
            % for domain m, that is excited by the primary MBF on domain n
            for m=1:numArrayEls

                % Extract basis function indices of domain m.
                domain_m_basis_functions = Solver_setup.rwg_basis_functions_domains{m};

                % 2018.06.03: We also support now interconnected domains. Calculate
                % the LU decomposition here for the particular domain (will not be
                % the same for each element)
                if (~Solver_setup.disconnected_domains)
                    % TO-DO: Actually use the calcZmn function here with the correct frequency index.
                    [L,U] = lu(zMatrices.values(domain_m_basis_functions, domain_m_basis_functions));

                    % In addition, we will also need to apply a windowing to the secondary MBF - similar to
                    % what was done for the primary MBF. This will be done below. Calculate here first the
                    % rwg coefficients on the interface (overlapping region) so that we can apply a windowing
                    % function.
                    if (true)
                        % -- Windowing  (only if we have interconnected domains)                        
                        % Let's first determine the BFs on the interface esssentially the difference between the 
                        % unknowns internal to the domain and that on the interface.
                        interface_basis_functions = setdiff(domain_m_basis_functions, ...
                            Solver_setup.rwg_basis_functions_internal_domains{m});                        
                    end%if
                end

                % Back-wards substitution with the part of the excitation vector
                % local to this domain
                count = 0;
                for n=1:numArrayEls 
                    if (m == n)
                        %ignore self-coupling - primary MBF already calculated
                        continue;
                    end%if

                    % Keep track of the number of secondary MBFs on domain
                    % m, if domain n has a primary to excite such a secondary MBF
                    if (Const.is_array_element_active(n,solNum))
                        count = count + 1;
                        mbfs.numSecMBFs(m,solNum) = count;                                  

                        % Extract basis function indices of domain n. See [1], if we have interconnected domains, 
                        % then we use the internal RWGs (i.e. not including the unknowns on the interface) for
                        % the source/basis MBFs.
                        
                        if (~Solver_setup.disconnected_domains)
                            domain_n_basis_functions = Solver_setup.rwg_basis_functions_internal_domains{n};
                        else
                            domain_n_basis_functions = Solver_setup.rwg_basis_functions_domains{n};
                        end                        

                        % Calculate the coupling matrix
                        % TO-DO: Actually use the calcZmn function here with the correct frequency index.
                        Zcoupl = zMatrices.values(domain_m_basis_functions,domain_n_basis_functions);
                        % Calculate the field coupling to domain m, using primary MBF from domain n
                        % Note: cf Eq. (4) in [1], the excitation vector resulting from the mutual 
                        % coupling has a negative sign! Be careful here when reusing these secondary 
                        % MBFs in the Jacobi Iterative Solver - then no negative sign is used.                        
                        Vcoupl =  - Zcoupl * mbfs.PrimIsol(domain_n_basis_functions,1,n,solNum);

                        % Solve now for the secondary induced MBF using the previously calculated 
                        % LU-decomposition of Zmm (stored in L and U)
                        b = L\Vcoupl;
                        mbfs.SecIsol(domain_m_basis_functions,count,m,solNum) = U\b;

                        % Window the secondary MBF here, if we are working with interconnected domains:
                        if (~Solver_setup.disconnected_domains && true)
                            % Apply now windowing : Factor of a half.
                            mbfs.SecIsol(interface_basis_functions,count,m,solNum) = 0.5.*mbfs.SecIsol(interface_basis_functions,count,m,solNum);
                        end%if
                    end%if
                end%for
            end        
            mbfs.secGenTime(solNum) = toc; % End timing
        else
            mbfs.secGenTime(solNum) = 0.0;
        end%if
    
% --------------------------------------------------------------------------------------------------
        % 2015-08-18: Reduce and orthonormalize MBFs (taken from CEASER2p5)
        if (Const.useMBFreduction)
            tic
            message_fc(Const,sprintf('Reduce and orthonormalise MBFs'));
            for m=1:numArrayEls            
                % Put all the MBFs in a column augmented matrix
                if (Const.calcSecMBFs)
                    origMBFs = [mbfs.PrimIsol(:,1,m,solNum) mbfs.SecIsol(:,1:mbfs.numSecMBFs(m,solNum),m,solNum)];
                else
                    origMBFs = mbfs.PrimIsol(:,1,m,solNum);
                end
                if (Const.debug)
                    message_fc(Const,['Number of initially generated CBFs: ' num2str(size(origMBFs,2))]);
                    message_fc(Const,'Reducing this number based on the user specified threshold...');
                end%if

                fcdString = sprintf('cbfm');
                redMBFs = reduceMBFset(Const, origMBFs, fcdString);
                %redMBFs = reduceMBFset(origMBFs,Const.MBFthreshold,Const.MBFplotSVspectrum);
                mbfs.RedIsol(:,1:size(redMBFs,2),m,solNum) = redMBFs;
                mbfs.numRedMBFs(m,solNum) = size(redMBFs,2);
                if (Const.debug)
                    message_fc(Const,['Number of retained orthonormal CBFs: ' num2str(size(redMBFs,2))]);
                end%if                
            end%for
            mbfs.svdTime(solNum) = toc; % End timing
        else
            mbfs.svdTime(solNum) = 0.0;
            message_fc(Const,sprintf('  No MBF reduction (+ orthonormalisation)'));
        end %if (Const.useMBFreduction)
% --------------------------------------------------------------------------------------------------
    end %for solNum = 1:numSols

    message_fc(Const,sprintf('Finished MBF generator'));
    % Output per solution configuration data
    totprimGenTime = 0;
    totsecGenTime  = 0;
    totsvdTime = 0;
    for solNum = 1:numSols
        % Calculate the total number of Primary and Secondary MBFs for the solution
        totPrimMBFs = 0;
        totSecMBFs  = 0;
        mbfs.totRedMBFs  = 0; % Store this for later reuse
        for n=1:numArrayEls
            totPrimMBFs = totPrimMBFs + mbfs.numPrimMBFs(n,solNum);
            totSecMBFs  = totSecMBFs  + mbfs.numSecMBFs(n,solNum);
            if (Const.useMBFreduction)
                mbfs.totRedMBFs = mbfs.totRedMBFs + mbfs.numRedMBFs(n,solNum);
            end%if
        end
        message_fc(Const,sprintf('Total number of Primary MBFs %d , Number of Second. MBFs %d for Sol. %d of %d',...
            totPrimMBFs, totSecMBFs, solNum, numSols));
        if (Const.useMBFreduction)
            message_fc(Const,sprintf('Total number of Reduced MBFs %d for Sol. %d of %d',...
            mbfs.totRedMBFs, solNum, numSols));
        end%if
        message_fc(Const,sprintf('Times for calculating Primary MBFs %f sec. and Second. MBFs %f sec. for Sol. %d of %d',...
            mbfs.primGenTime(solNum), mbfs.secGenTime(solNum), solNum, numSols));
        if (Const.useMBFreduction)
            message_fc(Const,sprintf('Times for calculating reduced MBFs (SVD) %f sec. for Sol. %d of %d',...
                mbfs.svdTime(solNum), solNum, numSols));
        end%if
        % Calculate the total time
        totprimGenTime = totprimGenTime + mbfs.primGenTime(solNum);
        totsecGenTime  = totsecGenTime  + mbfs.secGenTime(solNum);
        totsvdTime  = totsvdTime  + mbfs.svdTime(solNum);
    end
    % Output total time
    message_fc(Const,sprintf('Total Times for calculating Primary MBFs %f sec. and Second. MBFs %f sec.',totprimGenTime, totsecGenTime));
    if (Const.useMBFreduction)
        message_fc(Const,sprintf('Total Times for reducing MBFs (SVD) %f sec. ',totsvdTime));
    end%if    

    % We need to store also the MBF total time here - reported at the end of the CBFM solver when results are written
    % to file
    mbfs.totTime = totprimGenTime + totsecGenTime + totsvdTime;

