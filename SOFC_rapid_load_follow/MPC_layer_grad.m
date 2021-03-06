% MPC layer
function [output_plant, input_plant, last_config, P_plant, U_plant, eff_plant, modif] = MPC_layer(optimal_var,modif,Pel_target,Ucell_target,T_in,SOFC_data_nominal,SOFC_data_plant,M,m,lb,ub,initial_config)
global myProblem

yalmip('clear')

ns = 8; % # states
ni = 3; % # inputs
no = 2; % # outputs

x_ss = optimal_var(ni+1:end);
u_ss = optimal_var(1:3);
y_ss = [Pel_target; Ucell_target];

% Reformating constraints
M(:,4:end) = [];
lb = lb';
ub = ub';
lb(4:end)  = [];
ub(4:end)  = [];

%% ------------------------------
% Linearizing the system
% -------------------------------

[dotx,Ucell_opt,~,~,~,~,~] = fPrimeMyProject(0,optimal_var(4:end),optimal_var(1:3),T_in,SOFC_data_nominal);
[Ac,Bc,Cc,Dc] = MPC_linearization_mat(optimal_var,dotx,Pel_target,Ucell_opt,T_in,SOFC_data_nominal);

% Discrete time state-space model
sys = ss(Ac,Bc,Cc,Dc);

Ts = 10;  % Time sample
sys_d = c2d(sys,Ts,'zoh');

A = sys_d.A;
B = sys_d.B;
C = sys_d.C;
D = sys_d.D;

% Linearized steady states and input @ power setpoint
H = [C D; A-eye(ns) B];

target_config = H\[0; 0; zeros(ns+ni-no-1,1)];

%% MPC tracking
Q = 1*eye(ns);
% R_scaling = [ 1000/0.3   1/15   1/20 ];
% R = 100*diag(R_scaling);
R = 100*eye(ni);

N = 50;  % horizon length

% Variables
x_hat  = sdpvar(ns,N,'full');
x_target = sdpvar(ns,1,'full');
u_hat  = sdpvar(ni,N,'full');
u_target = sdpvar(ni,1,'full');
u_prev = sdpvar(ni,1,'full');

slew_rate = [0.001; 0.1; 0.5];

% Define constrainst and objective
con = [];
obj = 0;

con = con + ( -slew_rate <= u_hat(:,1)+u_ss-u_prev <= slew_rate );

for i = 1:N-1
    con = con + ( x_hat(:,i+1) == A*x_hat(:,i) + B*u_hat(:,i) );
    con = con + ( M*(u_hat(:,i)+u_ss) <= m );
    con = con + ( lb <= u_hat(:,i)+u_ss <= ub );
    
    con = con + ( -slew_rate <= u_hat(:,i+1)-u_hat(:,i) <= slew_rate );
    
    y(:,i) = C*x_hat(:,i) + D*u_hat(:,i) + y_ss;
    con = con + ( y(2,i) >= 0.7 );
    
    obj = obj + (x_hat(:,i)-x_target)'*Q*(x_hat(:,i)-x_target)...
              + (u_hat(:,i)-u_target)'*R*(u_hat(:,i)-u_target);
end

% slew_rate = repmat([0.001 0.1 0.5],N-1,1);
% con = con + ( -slew_rate(1,:)' <= u_hat(:,1)+u_ss-u_prev <= slew_rate(1,:)' );
% con = con + ( -slew_rate <= diff(u_hat,1,2)' <= slew_rate);

con = con + ( M*(u_hat(:,N)-u_target+u_ss) <= m );
con = con + ( lb <= u_hat(:,N)-u_target+u_ss <= ub );
obj = obj + (x_hat(:,i)-x_target)'*Q*(x_hat(:,i)-x_target)...
          + (u_hat(:,i)-u_target)'*R*(u_hat(:,i)-u_target);

% Parameters
parameters_in = {x_hat(:,1), x_target, u_target, u_prev};
solutions_out = {u_hat};

% Compile the matrices
controller = optimizer(con, obj, [], parameters_in, solutions_out);

%% Simulation non-linear plant model
Nsim = 200;
tol  = 5e-3;
opts = odeset('RelTol',1e-5,'AbsTol',1e-5);

x_setpoint = target_config(1:8);
u_target = target_config(9:11);
x_nonlin = initial_config(4:end);
xhat_nonlin = x_nonlin-x_ss;

u_previous = initial_config(1:3);
% u_prev_val(3) = u_prev_val(3) + 0.5;

for j = 1:Nsim
    [u_hat, infeasible] = controller{{xhat_nonlin(:,j), x_setpoint, u_target, u_previous}};
    u_nonlin(:,j) = u_hat(:,1)+u_ss;
    u_previous = u_nonlin(:,j);
    
    sol = ode15s(@(t,x) fPrimeMyProject(t,x,u_nonlin(:,j),T_in,SOFC_data_plant), [0 Ts], x_nonlin(:,j), opts);
    x_nonlin(:,j+1) = sol.y(:,end);
    xhat_nonlin(:,j+1) = x_nonlin(:,j+1) - x_ss;
    [~,U_plant(j),P_plant(j),~,~,~,eff_plant(j)] = fPrimeMyProject(0,x_nonlin(:,j+1),u_nonlin(:,j),T_in,SOFC_data_plant);
    
%     check_ss = norm(dx_states);
    check_steady_plant = norm(diff(x_nonlin(:,j:j+1),1,2));
    if check_steady_plant < tol
        break;
    end
end

input_plant  = u_nonlin;
output_plant = x_nonlin(:,1:end-1);
last_config = [u_nonlin(:,end); x_nonlin(:,end-1)];
% U_plant_hist = U_plant;
% P_plant_hist = P_plant;
% eff_plant_hist = eff_plant;
% 
% x_nonlin = initial_config(4:end)
% xhat_nonlin = initial_config(4:end);

% [tempsteady_nominal] = OPTIM_SteadyState(u_ss',x_ss',T_in,SOFC_data_plant);
% [~,U_nomtest,P_nomtest,~,~,~,~] = fPrimeMyProject(0,x_ss',u_nonlin(:,j),T_in,SOFC_data_plant);
% 
% for i = 1:3
%     for j = 1:Nsim
%         u_nonlin(:,j) = u_hat(:,1)+u_ss;
% 
%         sol = ode15s(@(t,x) fPrimeMyProject(t,x,u_nonlin(:,j),T_in,SOFC_data_plant), [0 Ts], x_nonlin(:,j), opts);
%         x_nonlin(:,j+1) = sol.y(:,end);
%         xhat_nonlin(:,j+1) = x_nonlin(:,j+1) - x_ss;
%         [~,U_plant(j),P_plant(j),~,~,~,eff_plant(j)] = fPrimeMyProject(0,x_nonlin(:,j+1),u_nonlin(:,j),T_in,SOFC_data_plant);
%         
%         check_steady_plant = norm(diff(x_nonlin(:,j:j+1),1,2));
%         if check_steady_plant < tol
%             break;
%         end
%     end
%     
% end


%% Simulation non-linear nominal model
% Nsim = 200;
% % opts = odeset('RelTol',1e-4,'AbsTol',1e-4);
% 
x_setpoint = target_config(1:8);
u_target = target_config(9:11);

x_nom = initial_config(4:end);
xhat_nom = x_nom-x_ss;

u_previous = initial_config(1:3);
% u_prev_val(3) = u_prev_val(3) + 0.2;

for j = 1:Nsim
    [u_hat, infeasible] = controller{{xhat_nom(:,j), x_setpoint, u_target, u_previous}};
    u_nonlin(:,j) = u_hat(:,1)+u_ss;
    
    
    u_previous = u_nonlin(:,j);
    
    sol = ode15s(@(t,x) fPrimeMyProject(t,x,u_nonlin(:,j),T_in,SOFC_data_nominal), [0 Ts], x_nom(:,j), opts);
    x_nom(:,j+1) = sol.y(:,end);
    xhat_nom(:,j+1) = x_nom(:,j+1) - x_ss;
    [~,U_nom(j),P_nom(j),~,~,~,~] = fPrimeMyProject(0,x_nom(:,j+1),u_nonlin(:,j),T_in,SOFC_data_nominal);
    
%     check_ss = norm(dx_states);
    check_steady_nom = norm(diff(x_nom(:,j:j+1),1,2));
    if check_steady_nom < tol
        break;
    end
end

[tempsteady_nominal] = OPTIM_SteadyState(u_ss',x_ss',T_in,SOFC_data_nominal);
[~,U_nomtest,P_nomtest,~,~,~,~] = fPrimeMyProject(0,x_ss',u_nonlin(:,j),T_in,SOFC_data_nominal);


%% Computing the modifiers
Kca = [0 0.9 0.9];
modif(2,4) = (1-Kca(2))*modif(2,4) + Kca(2)*(U_plant(end)-U_nom(end));    % Cell voltage
modif(3,4) = (1-Kca(3))*modif(3,4) + Kca(3)*(P_plant(end)-P_nom(end));        % Power set point

end