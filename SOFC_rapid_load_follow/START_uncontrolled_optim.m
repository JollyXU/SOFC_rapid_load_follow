clear all;
close all;
clc;

addpath('REFORMER','SOFC','COR','HEX','BURN');

%% ---------------------------
%  Initialization
% ----------------------------
global myProblem Ps_el it u_previous

% Number of cells :
N_c = 6;

prjname_SOFC       = 'Solid Oxide Fuel Cell';
prjname_myProblem  = 'Real Time Optimization';

SOFC_data_nominal = data_SOFC_nominal(prjname_SOFC,N_c);
SOFC_data_plant   = data_SOFC_plant(prjname_SOFC,N_c);
myProblem = data_myProblem(prjname_myProblem);

% --------------------------- PARAMETERS ----------------------------------
% Stream temperatures:
T_CH4_in  = 200.0; % [C]  methane stream  
T_H2O_in  = 200.0; % [C]  steam stream
T_air_in  = 30;    % [C]  air stream

T_in = [T_CH4_in T_H2O_in T_air_in] + SOFC_data_nominal.cst.K;

% --------------- Initial guess for the optimization ----------------------
% Initial State :
T_r0    = 550; % [C]   fuel reformer

T_el0   = 650; % [C]   electrolyte
T_i0    = 650; % [C]   interconnect 
T_fuel0 = 650; % [C]   fuel channel
T_air0  = 650; % [C]   air channel 

T_b0    = 1000; % [C]  burner

T_h0    = 650; % [C]   heat exchanger - fuel side
T_c0    = 600; % [C]   heat exchanger - air side

T_0 = [T_r0 T_el0 T_i0 T_fuel0 T_air0 T_b0 T_h0 T_c0] + SOFC_data_nominal.cst.K;

% SCTP - CNTP
R = 8.314462175;    % [J/K/mol] 
P = 100e3;          % [Pa]
T_st = 273.15;      % [K]

q_CH4inp      = 0.376129940461854; % [L/min]     methane flow rate
q_AIRcathinp  = 17.2531441172150; % [L/min]     methane flow rate
Iinp          = 19;               % [A]         current

u_0 = [q_CH4inp,q_AIRcathinp,Iinp];

% Initial guess for the optimization problem
u0 = [u_0 T_0];

% ------------------------ Optimal values ---------------------------------
Pel_opt    = [80 90 100];
Ucell_opt  = 0.7;
eff_opt    = [0.4297   0.4260  0.4226];
inputs_opt = [0.3163   0.3589  0.402;
              12.4936 13.8194 15.1185;
              19.0476 21.4286 23.8095];
          
output_opt = [0.6379 0.6325 0.6274;
              4.1479 4.0433 3.9493];

profile_setpoint = [1*ones(1,5) 2*ones(1,5)];  % PROFILE SETPOINT ---------

Ps_el = [];
Uopt_hist = [];
inputs_opt_hist = [];
eff_opt_hist = [];
for i = 1:size(profile_setpoint,2)
    Ps_el(i) = Pel_opt(profile_setpoint(i));
    inputs_opt_hist(:,i) = inputs_opt(:,profile_setpoint(i));
    output_opt_hist(:,i) = output_opt(:,profile_setpoint(i));
    eff_opt_hist(i) = eff_opt(profile_setpoint(i));
end

%% ---------------------------
% RTO Program
% ----------------------------
% ------------------------- Constraints -----------------------------------
ub = [2,50, 30, Inf*ones(1,8)];
lb = [1.36E-03,0.01/0.21, 0, -Inf*ones(1,8)];

Aeq = [];
beq = [];

Lair_upper = 10; 
Lair_lower = 3;
FU_upper   = 0.7;

kc = (6e+4)*N_c*R*T_st/(8*P*SOFC_data_nominal.cst.F);

A   = [2*Lair_lower,  -0.21,  0,  zeros(1,8);
      -2*Lair_upper,   0.21,  0,  zeros(1,8);
      -FU_upper,          0,  kc, zeros(1,8)];
B   =  [0;0;0];

myProblem.TC.TimeConstantOff = 0;

time_hist         = [];
states_plant_hist = [];
power_plant_hist  = [];
volt_plant_hist   = [];
FU_plant_hist     = [];
Lair_plant_hist   = [];
input_plant_hist  = [];
eff_plant_hist    = [];
duration_RTO      = 0;
duration_gradMod  = [];
duration_inputs   = 0;

grad_toggle = 1;        % toggle for computation of gradients

last_config = [0.3014; 12.0960; 19.0476; 895.4908; 1101.9426; 1101.3417; 1101.5156; 1101.1082; 1409.1253; 915.8712; 905.0253]; % intial states & inputs of the plant
modif = zeros(3,4);
tstart = 0;
Kca = [0 0.9 0.9];
Kgrad = 0.7;
deltaH = [1e-4 1e-2 1e-2];

opts_event = odeset('RelTol',1e-5,'AbsTol',1e-5,'Event',@event);
% ----------------------------- RTO loop ----------------------------------
for i = 1:size(profile_setpoint,2)
    it = i;
    % RTO layer
    [inOut_RTO] = RTO_layer(u0,modif,T_in,A,B,lb,ub,SOFC_data_nominal,myProblem.OPT.options);
    in_RTO      = inOut_RTO(1:3);
    out_RTO     = inOut_RTO(4:end);
    
    % Simulations
    [t_plant,y_plant] = ode15s(@fPrimeMyProject, [tstart Inf], last_config(4:end)',opts_event, in_RTO,T_in,SOFC_data_plant);
    for j = 2:size(y_plant,1)
        [dx_global,U_pla1,P_pla1,FU_pla,Lair_pla,~,eff_pla1] = fPrimeMyProject(0,y_plant(j,:),in_RTO,T_in,SOFC_data_plant);
        power_plant_hist = [power_plant_hist; P_pla1];
        volt_plant_hist  = [volt_plant_hist; U_pla1];
        FU_plant_hist    = [FU_plant_hist; FU_pla];
        Lair_plant_hist  = [Lair_plant_hist; Lair_pla];
        eff_plant_hist   = [eff_plant_hist; eff_pla1];
    end
    [x_mod] = OPTIM_SteadyState(in_RTO,out_RTO,T_in,SOFC_data_nominal);
    [~,U_nom1, P_nom1,~,~,~,eff_nom1] = fPrimeMyProject(0,x_mod,in_RTO,T_in,SOFC_data_nominal);
    
    last_config       = [in_RTO'; y_plant(end,:)'];
    u0                = last_config';
    time_hist         = [time_hist; t_plant(2:end)];
    states_plant_hist = [states_plant_hist; y_plant(2:end,:)];
    input_plant_hist  = [input_plant_hist; in_RTO];
    tstart            = t_plant(end);
    
    % Constraint adaptation
    modif(2,4) = (1-Kca(2))*modif(2,4) + Kca(2)*(volt_plant_hist(end)-U_nom1);    % Cell voltage
    modif(3,4) = (1-Kca(3))*modif(3,4) + Kca(3)*(power_plant_hist(end)-P_nom1);   % Power set point
    
    % Gradient computation
    if grad_toggle == 1
        for k = 1:3
            in_grad    = in_RTO;
            in_grad(k) = in_grad(k)+deltaH(k);
            [t_plant,y_plant_gra] = ode15s(@fPrimeMyProject, [tstart Inf], last_config(4:end)',opts_event, in_grad,T_in,SOFC_data_plant);

            for j = 2:size(y_plant_gra,1)
                [~,U_pla2,P_pla2,FU_pla,Lair_pla,~,eff_pla2] = fPrimeMyProject(0,y_plant_gra(j,:),in_grad,T_in,SOFC_data_plant);
                power_plant_hist = [power_plant_hist; P_pla2];
                volt_plant_hist  = [volt_plant_hist; U_pla2];
                FU_plant_hist    = [FU_plant_hist; FU_pla];
                Lair_plant_hist  = [Lair_plant_hist; Lair_pla];
                eff_plant_hist   = [eff_plant_hist; eff_pla2];
            end

            [x_mod] = OPTIM_SteadyState(in_grad,T_0,T_in,SOFC_data_nominal);
            [~,U_nom2, P_nom2,~,~,~,eff_nom2] = fPrimeMyProject(0,x_mod,in_grad,T_in,SOFC_data_nominal);

            grad_Ucell_nomnl(k) = (U_nom2-U_nom1)/deltaH(k);
            grad_Ucell_plant(k) = (U_pla2-U_pla1)/deltaH(k);
            grad_Power_nomnl(k) = (P_nom2-P_nom1)/deltaH(k);
            grad_Power_plant(k) = (P_pla2-P_pla1)/deltaH(k);
            grad_Effic_nomnl(k) = (eff_nom2-eff_nom1)/deltaH(k);
            grad_Effic_plant(k) = (eff_pla2-eff_pla1)/deltaH(k);

            time_hist         = [time_hist; t_plant(2:end)];
            states_plant_hist = [states_plant_hist; y_plant_gra(2:end,:)];
            input_plant_hist  = [input_plant_hist; in_grad];
            duration_gradMod  = [duration_gradMod tstart];
            duration_inputs   = [duration_inputs; tstart];
            
            last_config = [in_RTO'; y_plant_gra(end,:)'];
            tstart      = t_plant(end);
        end
        
        % Modifier adaptation
        modif(2,1:3) = (1-Kgrad)*modif(2,1:3) + Kgrad*(grad_Ucell_plant-grad_Ucell_nomnl); % Gradient cell voltage
        modif(3,1:3) = (1-Kgrad)*modif(3,1:3) + Kgrad*(grad_Power_plant-grad_Power_nomnl); % Gradient power
        modif(1,1:3) = (1-Kgrad)*modif(1,1:3) + Kgrad*(grad_Effic_plant-grad_Effic_nomnl); % Gradient efficiency
    end
    
    duration_RTO    = [duration_RTO; tstart];
    duration_inputs = [duration_inputs; tstart];
    u_previous      = in_RTO;
end


%% -----------------
% Generating plots
% ------------------
% Optimal values references
Popt_hist      = Ps_el;
Uopt_hist      = Ucell_opt*ones(1,size(Ps_el,2));
RTO_cycle      = duration_RTO'/3600;
RTO_cycle      = [RTO_cycle; RTO_cycle];
Gradient_cycle = duration_gradMod/3600;
Gradient_cycle = [Gradient_cycle; Gradient_cycle];

set(0,'DefaultFigureWindowStyle','docked')

figure('Name','power','Color','w')
power_graph(1) = plot(time_hist/3600,power_plant_hist,'Linewidth',1);
hold on
power_graph(2) = stairs(duration_RTO/3600,[Popt_hist Popt_hist(end)],'--','Linewidth',1);
ylim = get(gca,'ylim');
power_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
if grad_toggle == 1
    power_graph_grad = line(Gradient_cycle, get(gca,'ylim'), 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
    lgd = legend([power_graph power_graph_RTO(1) power_graph_grad(1) ] ,'plant','reference','RTO cycle','gradient computation','Location','northwest');
else
    lgd = legend([power_graph power_graph_RTO(1)] ,'plant','reference','RTO cycle','Location','northwest');
end
lgd.Interpreter = 'latex';
xlabel('Time [h]','Interpreter','latex');
ylabel('Power $P_{el}$ [W]','Interpreter','latex');
title('Power','Interpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')

% Efficiency
figure('Name','efficiency')
eff_graph(1) = plot(time_hist/3600,eff_plant_hist,'LineWidth',1);
hold on
eff_graph(2) = stairs(duration_RTO/3600, [eff_opt_hist eff_opt_hist(end)], '--','Linewidth',1);
ylim = get(gca,'ylim') + [0.0001 -0.0001];
eff_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
if grad_toggle == 1
    eff_graph_grad = line(Gradient_cycle, ylim, 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
    lgd = legend([eff_graph eff_graph_RTO(1) eff_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation');
else
    lgd = legend([eff_graph eff_graph_RTO(1)],'plant','plant optimum','RTO cycle');
end
lgd.Interpreter = 'latex';
xlabel('Time [h]','Interpreter','latex');
ylabel('Efficiency $\eta$ [-]','Interpreter','latex')
title('Efficiency of the fuel cell','Interpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')

% Cell voltage
figure('Name','voltage')
volt_graph(1) = plot(time_hist/3600,volt_plant_hist,'LineWidth',1);
hold on
volt_graph(2) = stairs(duration_RTO/3600, [Uopt_hist Uopt_hist(end)], '--','Linewidth',1);
ylim = get(gca,'ylim') + [0.0001 -0.0001];
volt_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
if grad_toggle == 1
    volt_graph_grad = line(Gradient_cycle, ylim, 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
    lgd = legend([volt_graph volt_graph_RTO(1) volt_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','southeast');
else
    lgd = legend([volt_graph volt_graph_RTO(1)],'plant','lower limit','RTO cycle','Location','southeast');
end
lgd.Interpreter = 'latex';
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')
xlabel('Time [h]');
ylabel('Voltage U_{cell} [V]');
title('Efficiency of the fuel cell')

% Fuel utilization
figure('Name','FU')
FU_graph(1) = plot(time_hist/3600,FU_plant_hist,'LineWidth',1);
hold on
FU_graph(2) = stairs(duration_RTO/3600, [output_opt_hist(1,:) output_opt_hist(1,end)], '--','Linewidth',1);
ylim = get(gca,'ylim') + [0.0001 -0.0001];
FU_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
if grad_toggle == 1
    FU_graph_grad = line(Gradient_cycle, ylim, 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
    lgd = legend([FU_graph FU_graph_RTO(1) FU_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','northeast');
else
    lgd = legend([FU_graph FU_graph_RTO(1)],'plant','plant optimum','RTO cycle','Location','northeast');
end
lgd.Interpreter = 'latex';
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')
xlabel('Time [h]');
ylabel('Fuel utilization $FU$ [-]','Interpreter','latex');
title('Fuel utilization')

% Air ratio
figure('Name','Lair')
Lair_graph(1) = plot(time_hist/3600,Lair_plant_hist,'LineWidth',1);
hold on
Lair_graph(2) = stairs(duration_RTO/3600, [output_opt_hist(2,:) output_opt_hist(2,end)], '--','Linewidth',1);
ylim = get(gca,'ylim') + [0.0001 -0.0001];
Lair_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
if grad_toggle == 1
    Lair_graph_grad = line(Gradient_cycle, ylim, 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
    lgd = legend([Lair_graph Lair_graph_RTO(1) Lair_graph_grad(1)],'plant','upper limit','RTO cycle','gradient computation','Location','northeast');
else
    lgd = legend([Lair_graph Lair_graph_RTO(1)],'plant','upper limit','RTO cycle','Location','northeast');
end
lgd.Interpreter = 'latex';
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')
xlabel('Time [h]','Interpreter','latex');
ylabel('Air ratio $\lambda_{air}$ [-]','Interpreter','latex');
title('Efficiency','Interpreter','latex')

% Methane
figure('Name','CH4 input')
inCH4_graph(1) = stairs(duration_inputs/3600,[input_plant_hist(:,1); input_plant_hist(end,1)],'LineWidth',1);
hold on
inCH4_graph(2) = stairs(duration_RTO/3600,[inputs_opt_hist(1,:) inputs_opt_hist(1,end)],'--','Linewidth',1);
ylim = get(gca,'ylim')+[0 -0.0001];
inCH4_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
if grad_toggle == 1
    inCH4_graph_grad = line(Gradient_cycle, ylim, 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
    lgd = legend([inCH4_graph inCH4_graph_RTO(1) inCH4_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','northwest');
else
    lgd = legend([inCH4_graph inCH4_graph_RTO(1)],'plant','plant optimum','RTO cycle','Location','northwest');
end
lgd.Interpreter = 'latex';
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')
xlabel('Time [h]');
ylabel('Flow $\dot{q}_{CH4}$ [L/min]','Interpreter','latex')
title('Flow methane $\dot{q}_{CH4}$ [L/min]','Interpreter','latex')

% Air
figure('Name','air input')
inAir_graph(1) = stairs(duration_inputs/3600,[input_plant_hist(:,2); input_plant_hist(end,2)],'LineWidth',1);
hold on
inAir_graph(2) = stairs(duration_RTO/3600,[inputs_opt_hist(2,:) inputs_opt_hist(2,end)],'--','Linewidth',1);
ylim = get(gca,'ylim')+[0 -0.0001];
inAir_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
if grad_toggle == 1
    inAir_graph_grad = line(Gradient_cycle, ylim, 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
    lgd = legend([inAir_graph inAir_graph_RTO(1) inAir_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','northwest');
else
    lgd = legend([inAir_graph inAir_graph_RTO(1)],'plant','plant optimum','RTO cycle','Location','northwest');
end
lgd.Interpreter = 'latex';
xlabel('Time [h]','Interpreter','latex')
ylabel('Flow Air $\dot{q}_\mathrm{air}$ [L/min]','Interpreter','latex')
title('Flow Air $\dot{q}_{CH4}$','Interpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')

% Current
figure('Name','current input')
inCurrent_graph(1) = stairs(duration_inputs/3600,[input_plant_hist(:,3); input_plant_hist(end,3)],'LineWidth',1);
hold on
inCurrent_graph(2) = stairs(duration_RTO/3600,[inputs_opt_hist(3,:) inputs_opt_hist(3,end)],'--','Linewidth',1);
inCurrent_graph_RTO = line(RTO_cycle, get(gca,'ylim'),'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
if grad_toggle == 1
    inCurrent_graph_grad = line(Gradient_cycle, get(gca,'ylim'), 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
    lgd = legend([inCurrent_graph inCurrent_graph_RTO(1) inCurrent_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','northwest');
else
    lgd = legend([inCurrent_graph inCurrent_graph_RTO(1)],'plant','plant optimum','RTO cycle','Location','northwest');
end
lgd.Interpreter = 'latex';
xlabel('Time [h]','Interpreter','latex')
ylabel('Current [A]','Interpreter','latex')
title('Current','Interpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')