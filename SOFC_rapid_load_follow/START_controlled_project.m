% ----------------------------------------------
%              Semester Project
% Real-time optimization of a fuell cell system
%         in rapid load following SOFC
%
%     Student: Frederic NGUYEN
% Supervisors: Tafarel DE AVILA FERREIRA
%              Altug BITLISLIOGLU
%   Professor: Dominique BONVIN
% ----------------------------------------------

% Main entry of the program

%%
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

% Parameters
% Stream temperatures:
T_CH4_in  = 200.0; % [C]  methane stream  
T_H2O_in  = 200.0; % [C]  steam stream
T_air_in  = 30;    % [C]  air stream

T_in = [T_CH4_in T_H2O_in T_air_in] + SOFC_data_nominal.cst.K;

% -----------------------------------
% Initial guess for the optimization
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

% Optimal values for comparison with simulation results
Pel_opt    = [80 90 100];
Ucell_opt  = 0.7;
eff_opt    = [0.4297   0.4260  0.4226];
inputs_opt = [0.3163   0.3589  0.402;
              12.4936 13.8194 15.1185;
              19.0476 21.4286 23.8095];          
output_opt = [0.6379 0.6325 0.6274;
              4.1479 4.0433 3.9493];

profile_setpoint = [1*ones(1,5) 2*ones(1,5)];  % profile setpoint

Ps_el           = [];
Uopt_hist       = [];
eff_opt_hist    = [];
inputs_opt_hist = [];
for i = 1:size(profile_setpoint,2)
    Ps_el(i) = Pel_opt(profile_setpoint(i));
    inputs_opt_hist(:,i) = inputs_opt(:,profile_setpoint(i));
    output_opt_hist(:,i) = output_opt(:,profile_setpoint(i));
    eff_opt_hist(i) = eff_opt(profile_setpoint(i));
end

%% ---------------
% Simulation
% ----------------
% Constraints
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

% Simulation
myProblem.TC.TimeConstantOff = 0;
last_config = [0.3014; 12.0960; 19.0476; 895.4908; 1101.9426; 1101.3417; 1101.5156; 1101.1082; 1409.1253; 915.8712; 905.0253]; % intial states & inputs of the plant
modif       = zeros(3,4);

states_plant_hist = [];
power_plant_hist  = [];
volt_plant_hist   = [];
FU_plant_hist     = [];
Lair_plant_hist   = [];
input_plant_hist  = [];
eff_plant_hist    = [];
duration_time = [];
duration_grad = [];
duration_RTO  = 0;

for i = 1:size(profile_setpoint,2)
    % ----------------------------
    %  RTO layer
    % ----------------------------
    it = i;
    [InOut_opt] = RTO_layer(u0,modif,T_in,A,B,lb,ub,SOFC_data_nominal,myProblem.OPT.options);

    % ----------------------------
    %  MPC layer
    % ----------------------------
    tic
    [states_plant, input_plant, last_config, P_plant, U_plant, FU_plant, Lair_plant, eff_plant, output_nompla, modif] = MPC_epsilon(InOut_opt',modif,Ps_el(it),Ucell_opt,T_in,SOFC_data_nominal,SOFC_data_plant,A,B,lb,ub,last_config);
    
    states_plant_hist = [states_plant_hist states_plant];
    input_plant_hist  = [input_plant_hist input_plant];
    power_plant_hist  = [power_plant_hist P_plant];
    volt_plant_hist   = [volt_plant_hist U_plant];
    FU_plant_hist     = [FU_plant_hist FU_plant];
    Lair_plant_hist   = [Lair_plant_hist Lair_plant];
    eff_plant_hist    = [eff_plant_hist eff_plant];
    
    duration_time(i)  = size(states_plant,2);
    duration_temp     = size(states_plant_hist,2);
    
    [states_plant, input_plant, last_config, P_plant, U_plant, FU_plant, Lair_plant, eff_plant, modif,duration_inputs] = MPC_grad(InOut_opt',output_nompla,modif,Ps_el(it),Ucell_opt,T_0,T_in,SOFC_data_nominal,SOFC_data_plant,A,B,lb,ub,last_config,0);
    states_plant_hist = [ states_plant_hist states_plant];
    input_plant_hist  = [input_plant_hist input_plant];
    power_plant_hist  = [power_plant_hist P_plant];
    volt_plant_hist   = [volt_plant_hist U_plant];
    FU_plant_hist     = [FU_plant_hist FU_plant];
    Lair_plant_hist   = [Lair_plant_hist Lair_plant];
    eff_plant_hist    = [eff_plant_hist eff_plant];
    toc
    u_previous = InOut_opt(1:3);
    duration_grad = [duration_grad, duration_inputs+duration_temp];
    duration_time(i)  = duration_time(i) + size(states_plant,2);
    duration_RTO(i+1) = duration_time(i) + duration_RTO(i);
    
    u0 = last_config';
end

%% Optimal values
Popt_hist = repelem(Ps_el,duration_time);
Uopt_hist = Ucell_opt*ones(1,size(volt_plant_hist,2));
% for i = 1:size(duration_RTO,2)-1
%     duration
% end
eff_opt_hist = repelem(eff_opt_hist,duration_time);
inputs_opt_hist = repelem(inputs_opt_hist,1,duration_time);

%% Post-processing result
set(0,'DefaultFigureWindowStyle','normal')
close all

Ts = 10; % [s] time sample
time_step  = [1:1:size(states_plant_hist,2)]*Ts/3600;
RTO_cycle  = [0 duration_RTO; 0 duration_RTO]*Ts/3600;
grad_cycle = [duration_grad; duration_grad]*Ts/3600;


figure('Name','power','Color','w','Units','centimeters','Position',[5 5 18 7])
power_graph      = plot(time_step, power_plant_hist,time_step,Popt_hist,'--','LineWidth',2);
power_graph_RTO  = line(RTO_cycle, get(gca,'ylim'),'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
power_graph_grad = line(grad_cycle, get(gca,'ylim'), 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
lgd = legend([power_graph' power_graph_RTO(1) power_graph_grad(1) ] ,'plant','plant optimum','RTO cycle','gradient computation','Location','southeast');
% lgd.Interpreter = 'latex';
xlabel('Time [h]')
ylabel('Power P_{el} [W]')
% title('Power delivered by the system','Interpreter','latex')
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'TickLabelInterpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
print('graphs\MPC_RTO_power','-dpng','-r300')

%%
figure('Name','efficiency','Color','w','Units','centimeters','Position',[5 5 18 7])
eff_graph      = plot(time_step, eff_plant_hist,time_step,eff_opt_hist,'--','LineWidth',2);
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
eff_graph_RTO  = line(RTO_cycle, get(gca,'ylim')+ [0 0.009],'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
eff_graph_grad = line(grad_cycle, get(gca,'ylim')+ [0 0], 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
lgd = legend([eff_graph' eff_graph_RTO(1) eff_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation');
% lgd.Interpreter = 'latex';
xlabel('Time [h]')
ylabel('Efficiency \eta [-]')
% title('Efficiency of the the system','Interpreter','latex')
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'TickLabelInterpreter','latex')
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
print('graphs\MPC_RTO_efficiency','-dpng','-r300')


%% OUTPUTS
figure('Name','voltage','Color','w','Units','centimeters','Position',[5 5 18 7])
volt_graph      = plot(time_step, volt_plant_hist,time_step,Uopt_hist,'--','LineWidth',2);
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
volt_graph_RTO  = line(RTO_cycle, get(gca,'ylim'),'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
volt_graph_grad = line(grad_cycle, get(gca,'ylim'), 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
lgd = legend([volt_graph' volt_graph_RTO(1) volt_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation');
lgd.Interpreter = 'latex';
xlabel('Time [h]')
ylabel('Voltage U_{cell} [V]')
% title('Voltage of the cell','Interpreter','latex')
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'TickLabelInterpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
print('graphs\MPC_RTO_voltage','-dpng','-r300')
%%
figure('Name','FU','Units','centimeters','Position',[5 5 18 7])
FU_graph(1) = plot(time_step,FU_plant_hist,'LineWidth',2);
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
hold on
FU_graph(2) = stairs(duration_RTO*Ts/3600, [output_opt_hist(1,:) output_opt_hist(1,end)], '--','Linewidth',2);
ylim = get(gca,'ylim') + [0.0001 -0.0001];
FU_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
FU_graph_grad = line(grad_cycle, ylim, 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
lgd = legend([FU_graph FU_graph_RTO(1) FU_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','southeast');
% lgd.Interpreter = 'latex';
xlabel('Time [h]');
ylabel('Fuel utilization FU [-]');
% title('Efficiency of the fuel cell')
print('graphs\MPC_RTO_FU','-dpng','-r300')

figure('Name','Lair','Units','centimeters','Position',[5 5 18 7])
Lair_graph(1) = plot(time_step,Lair_plant_hist,'LineWidth',2);
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'LineWidth',1,'TickLabelInterpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
hold on
Lair_graph(2) = stairs(duration_RTO*Ts/3600, [output_opt_hist(2,:) output_opt_hist(2,end)], '--','Linewidth',2);
ylim = get(gca,'ylim') + [0.0001 -0.0001];
Lair_graph_RTO = line(RTO_cycle, ylim,'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
Lair_graph_grad = line(grad_cycle, ylim, 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
lgd = legend([Lair_graph Lair_graph_RTO(1) Lair_graph_grad(1)],'plant','upper limit','RTO cycle','gradient computation','Location','southeast');
% lgd.Interpreter = 'latex';
xlabel('Time [h]');
ylabel('Air ratio \lambda_{air} [-]');
% title('Efficiency of the fuel cell')
print('graphs\MPC_RTO_Lair','-dpng','-r300')


%% INPUTS
figure('Name','methane','Color','w','Units','centimeters','Position',[5 5 18 7])
[ts,ys] = stairs(time_step, input_plant_hist(1,:));
inCH4_graph = plot(ts, ys,time_step,inputs_opt_hist(1,:),'--','Linewidth',2);
inCH4_graph_RTO = line(RTO_cycle, get(gca,'ylim'),'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
inCH4_graph_grad = line(grad_cycle, get(gca,'ylim'), 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
lgd = legend([inCH4_graph' inCH4_graph_RTO(1) inCH4_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','southeast');
% lgd.Interpreter = 'latex';
xlabel('Time [h]')
ylabel('Methane flow q_{CH4} [L/min]')
% title('Methane flow rate','Interpreter','latex')
% legend({'plant','optimal'},'Interpreter','latex')
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'TickLabelInterpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
print('graphs\MPC_RTO_CH4','-dpng','-r300')
%%
figure('Name','air','Color','w','Units','centimeters','Position',[5 5 18 7])
[ts,ys] = stairs(time_step, input_plant_hist(2,:));
inAir_graph      = plot(ts, ys,time_step,inputs_opt_hist(2,:),'--','Linewidth',2);
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
inAir_graph_RTO  = line(RTO_cycle, get(gca,'ylim'),'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
inAir_graph_grad = line(grad_cycle, get(gca,'ylim'), 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
lgd = legend([inAir_graph' inAir_graph_RTO(1) inAir_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','southeast');
% lgd.Interpreter = 'latex';
xlabel('Time [h]')
ylabel('Air flow rate q_{air} [L/min]')
% title('Air flow rate','Interpreter','latex')
% legend({'plant','optimal'},'Interpreter','latex')
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'TickLabelInterpreter','latex')
print('graphs\MPC_RTO_air','-dpng','-r300')

figure('Name','current','Color','w','Units','centimeters','Position',[5 5 18 7])
[ts,ys] = stairs(time_step, input_plant_hist(3,:));
inCurrent_graph      = plot(ts, ys,time_step,inputs_opt_hist(3,:),'--','Linewidth',2);
inCurrent_graph_RTO  = line(RTO_cycle, get(gca,'ylim'),'Color',[0.1 0.1 0.1],'LineStyle','--','LineWidth',0.75);
inCurrent_graph_grad = line(grad_cycle, get(gca,'ylim'), 'Color',[0.4 0.4 0.4],'LineStyle',':','LineWidth',0.5);
lgd = legend([inCurrent_graph' inCurrent_graph_RTO(1) inCurrent_graph_grad(1)],'plant','plant optimum','RTO cycle','gradient computation','Location','southeast');
% lgd.Interpreter = 'latex';
xlabel('Time [h]')
ylabel('Current I [A]')
% title('Current','Interpreter','latex')
% set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',12,'TickLabelInterpreter','latex')
set(gca,'Box','off','FontUnits','points','FontWeight','normal','FontSize',14,'FontName','Roboto Condensed')
print('graphs\MPC_RTO_current','-dpng','-r300')