classdef FluidUtils
    %FluidUtils  Shared static methods for Stam stable-fluids solvers.
    %   Provides fast bilinear interpolation, semi-Lagrangian advection,
    %   and FFT Poisson pressure projection used by FluidSim, Dobryakov,
    %   Smoke, Fire, and other fluid-based games.
    %
    %   All methods are static -- no instantiation needed.
    %   Usage: games.FluidUtils.fldAdvect(field, u, v, dt, X, Y, Ny, Nx)
    %
    %   See also games.FluidSim, GameBase

    methods (Static)

        function q = fastBilerp(field, Xb, Yb, Ny, Nx)
            %fastBilerp  Fast bilinear interpolation via floor + linear indexing.
            %   2-3x faster than interp2 for grid-based fluid advection.
            x0 = floor(Xb); y0 = floor(Yb);
            x1 = min(x0 + 1, Nx); y1 = min(y0 + 1, Ny);
            x0 = max(x0, 1); y0 = max(y0, 1);
            sx = Xb - x0; sy = Yb - y0;
            idx00 = y0 + (x0 - 1) * Ny;
            idx10 = y0 + (x1 - 1) * Ny;
            idx01 = y1 + (x0 - 1) * Ny;
            idx11 = y1 + (x1 - 1) * Ny;
            q = field(idx00) .* (1 - sx) .* (1 - sy) + ...
                field(idx10) .* sx .* (1 - sy) + ...
                field(idx01) .* (1 - sx) .* sy + ...
                field(idx11) .* sx .* sy;
        end

        function result = fldAdvect(field, u, v, dt, X, Y, Ny, Nx)
            %fldAdvect  Semi-Lagrangian advection with clamped boundaries.
            %   Backtraces each grid cell along the velocity field and
            %   interpolates the source value via bilinear interpolation.
            Xb = X - dt * u;
            Yb = Y - dt * v;
            Xb = max(1, min(Nx, Xb));
            Yb = max(1, min(Ny, Yb));
            result = games.FluidUtils.fastBilerp(field, Xb, Yb, Ny, Nx);
        end

        function [u, v] = fldProject(u, v, eigvals, ~, ~)
            %fldProject  FFT Poisson pressure projection for divergence-free field.
            %   Uses backward-diff divergence + forward-diff gradient, which
            %   compose exactly to the 5-point Laplacian (machine-precision
            %   zero divergence after projection).

            % Divergence (backward differences -- consistent with Laplacian)
            dudx = u - u(:, [end, 1:end-1]);
            dvdy = v - v([end, 1:end-1], :);
            divField = dudx + dvdy;

            % Solve Poisson: Laplacian(p) = div via FFT
            pHat = fft2(divField) ./ eigvals;
            pHat(1, 1) = 0;  % zero mean pressure
            pField = real(ifft2(pHat));

            % Subtract pressure gradient (forward differences -- consistent)
            dpdx = pField(:, [2:end, 1]) - pField;
            dpdy = pField([2:end, 1], :) - pField;
            u = u - dpdx;
            v = v - dpdy;
        end

    end
end
