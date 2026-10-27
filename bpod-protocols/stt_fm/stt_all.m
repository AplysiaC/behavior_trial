% STT unified protocol. Choose shaping or train at session start.
% One Bpod state matrix is generated per run; all task logic is in this file.
classdef stt_all < proto.ProtoObj
    % Sequence Transfer Task. One Bpod state matrix is generated per trial.
    % All timings and port assignments below are provisional test settings.

    properties
        mode = 'train'
        prompt_mode = true
        stage = 1
        trial_stage = NaN
        stage_completed_trials = 0
        stage_rewarded_trials = 0
        stage_performance = NaN
        stage_trial_number = NaN
        stage_hit_history = []
        stage_advance_trials = []
        shaping_complete = false
        pending_training = false
        daily_evaluated = false
        hold_break_count = [0 0 0]
        phase = 'A'
        target_sequence = {}
        trial_phase = 'A'
        b_condition = 'B1'
        trial_since_switch = 0
        a_completed_trials = 0
        b_completed_trials = 0
        counted_trials = 0
        trial_started = false
        trial_number = NaN
        switch_after_trial = NaN
        a_hit_history = []
        trial_timing = struct()
        outcome = ''
        violation_port = ''
        violation_step = NaN
        timeout_state = ''
        a_consistent_error = false
        restart_count = 0
        error_count = 0
        error_poke_ports = {}
        error_poke_steps = []
        wrong_poke_ports = {}
        wrong_poke_steps = []
        clean_hit = false
        poke_times = []
        poke_types = {}
        step_latency = [NaN NaN NaN NaN]
        delivered_reward_ul = 0
    end

    methods
        function [x,y] = init(obj,varargin)
            [x,y] = init@proto.ProtoObj(obj,varargin{:});
            obj.trial_time_limit = 400;
        end

        function useSettings(obj,settings_name,expg_data,subj_data)
            if nargin < 2, settings_name = []; end
            if nargin < 3, expg_data = []; end
            if nargin < 4, subj_data = []; end
            selection = struct('mode',obj.mode,'prompt_mode',obj.prompt_mode);
            if ~isempty(expg_data), selection = utils.apply_struct(selection,expg_data); end
            if ~isempty(subj_data), selection = utils.apply_struct(selection,subj_data); end
            assert(islogical(selection.prompt_mode) && isscalar(selection.prompt_mode), ...
                'stt_all:Settings','prompt_mode must be true or false.');
            if selection.prompt_mode, selection.mode = stt_all.promptMode(); end
            assert(ismember(selection.mode,{'shaping','train'}), ...
                'stt_all:Settings','mode must be shaping or train.');
            obj.mode = selection.mode;
            obj.prompt_mode = selection.prompt_mode;
            if strcmp(obj.mode,'shaping')
                obj.useShapingSettings(settings_name,expg_data,subj_data);
                return;
            end
            if nargin < 2 || isempty(settings_name), settings_name = 'stt'; end
            if nargin < 3, expg_data = []; end
            if nargin < 4, subj_data = []; end
            s = struct();
            s.name = settings_name;
            % Coordinates: MidC=(0,0), BotL=(-1,-1), MidL=(-2,0),
            % TopR=(1,1), TopL=(-1,1), MidR=(2,0), BotR=(1,-1).
            % Four pokes per sequence: MidC plus three target ports.
            % A and B1 were supplied as three displacement rows, accumulated
            % from MidC. B3 was supplied as three absolute target-port positions.
            % B2 mirrors A's target-port positions across the y-axis.
            s.sequence_A = {'MidC','BotL','MidL','TopR'};
            s.sequence_B1 = {'MidC','BotL','TopL','MidR'}; % similar
            s.sequence_B2 = {'MidC','BotR','MidR','TopL'}; % y-axis mirror
            s.sequence_B3 = {'MidC','TopL','BotR','MidR'}; % disjoint peripheral ports
            s.b_condition = 'B1';
            s.prompt_session = true;      % ask at each start_protocol run
            s.run_mode = 'A_only';         % used when prompt_session is false
            s.switch_mode = 'manual';      % 'manual', 'fixed', or 'performance'
            s.a_trial_count = 0;           % switch after this many completed A trials
            s.performance_min_trials = 50;
            s.performance_window = 20;
            s.performance_threshold = 0.80;
            s.T_first = 30;
            s.T_start_min = 0.1;
            s.T_start_max = 0.2;
            s.T_second = 10;
            s.T_second_hold = 0.1;        % provisional 100 ms q2 hold
            s.T_third_hold = 0.1;
            s.T_fourth = 10;
            s.T_release = 0.01;           % brief transition after q4
            s.T_third = 10;
            s.T_reward = 10;
            s.T_error = 0.2;
            s.T_timeout = 0.01;
            s.ITI_min = 0.5;
            s.ITI_max = 1.5;
            s.reward_ul = 5;              % provisional; check calibration
            s.led_brightness = 255;
            s.early_start_policy = 'restart';  % restart / violation / ignore
            s.early_second_policy = 'retry';   % retry / violation / ignore
            % Restored between sessions only if explicitly supplied by the lab.
            s.phase = 'A';
            s.a_completed_trials = 0;
            s.b_completed_trials = 0;
            s.a_hit_history = [];
            s.switch_after_trial = NaN;
            if ~isempty(expg_data), s = utils.apply_struct(s,expg_data); end
            if ~isempty(subj_data), s = utils.apply_struct(s,subj_data); end
            if s.prompt_session
                s = stt_all.promptRunMode(s);
                % The prompted switch trial is counted within this session.
                s.a_completed_trials = 0;
                s.b_completed_trials = 0;
                s.a_hit_history = [];
                s.switch_after_trial = NaN;
            end
            s = stt_all.configureRunMode(s);
            stt_all.validateSettings(s);
            obj.settings = s;
            obj.phase = s.phase;
            obj.b_condition = s.b_condition;
            obj.a_completed_trials = s.a_completed_trials;
            obj.b_completed_trials = s.b_completed_trials;
            obj.counted_trials = s.a_completed_trials + s.b_completed_trials;
            obj.a_hit_history = s.a_hit_history;
            obj.switch_after_trial = s.switch_after_trial;
            fprintf('STT session: %s, phase %s, B condition %s, switch after %d A trials.\n', ...
                s.run_mode,obj.phase,obj.b_condition,s.a_trial_count);
        end

        function prepareNextTrial(obj)
            if strcmp(obj.mode,'shaping')
                obj.prepareShapingTrial();
                return;
            end
            s = obj.settings;
            obj.trial_phase = obj.phase;
            if strcmp(obj.phase,'A')
                obj.target_sequence = s.sequence_A;
                obj.trial_since_switch = 0;
            else
                obj.target_sequence = s.(['sequence_' s.b_condition]);
                obj.trial_since_switch = obj.b_completed_trials + 1;
            end
            fprintf('STT trial %d: %s -> %s -> %s -> %s, then BotC.\n', ...
                obj.n_started_trials,obj.target_sequence{:});
            obj.trial_timing = struct('T_first',s.T_first, ...
                'T_start',stt_all.jitter(s.T_start_min,s.T_start_max), ...
                'T_second',s.T_second,'T_second_hold',s.T_second_hold, ...
                'T_third',s.T_third,'T_third_hold',s.T_third_hold, ...
                'T_fourth',s.T_fourth,'T_release',s.T_release, ...
                'T_reward',s.T_reward,'T_error',s.T_error, ...
                'T_timeout',s.T_timeout,'ITI',stt_all.jitter(s.ITI_min,s.ITI_max));
            obj.outcome = '';
            obj.violation_port = '';
            obj.violation_step = NaN;
            obj.timeout_state = '';
            obj.a_consistent_error = false;
            obj.restart_count = 0;
            obj.error_count = 0;
            obj.error_poke_ports = {};
            obj.error_poke_steps = [];
            obj.trial_started = false;
            obj.trial_number = NaN;
            obj.wrong_poke_ports = {};
            obj.wrong_poke_steps = [];
            obj.clean_hit = false;
            obj.poke_times = [];
            obj.poke_types = {};
            obj.step_latency = [NaN NaN NaN NaN];
            obj.delivered_reward_ul = 0;
        end

        function SMA = generateSM(obj)
            if strcmp(obj.mode,'shaping')
                SMA = obj.generateShapingSM();
                return;
            end
            s = obj.settings;
            t = obj.trial_timing;
            q = obj.target_sequence;
            all_lights = stt_all.ledActions(q,s.led_brightness);
            after_q1_lights = stt_all.ledActions(q(2:4),s.led_brightness);
            after_q2_lights = stt_all.ledActions(q(3:4),s.led_brightness);
            q4_light = stt_all.ledActions(q(4),s.led_brightness);
            % Register every PortArray pattern before AddState maps LED aliases.
            SMA = sma.newStateMachine({all_lights,after_q1_lights, ...
                after_q2_lights,q4_light});

            start_conditions = {'Tup','WaitForSecondPoke','OtherIn','Violation'};
            switch s.early_start_policy
                case 'restart'
                    start_conditions = [start_conditions,{[q{1} 'Out'],'WaitForFirstPoke'}];
                case 'violation'
                    start_conditions = [start_conditions,{[q{1} 'Out'],'Violation'}];
            end
            second_conditions = {'Tup','WaitForThirdPoke','OtherIn','Violation'};
            switch s.early_second_policy
                case 'retry'
                    second_conditions = [second_conditions,{[q{2} 'Out'],'WaitForSecondPoke'}];
                case 'violation'
                    second_conditions = [second_conditions,{[q{2} 'Out'],'Violation'}];
            end
            third_conditions = {'Tup','WaitForFourthPoke', ...
                [q{3} 'Out'],'WaitForThirdPoke','OtherIn','Violation'};

            SMA = sma.AddState(SMA,'Name','WaitForFirstPoke','Timer',t.T_first, ...
                'StateChangeConditions',{[q{1} 'In'],'StartInterval','OtherIn','Violation','Tup','TrialTimeOut'}, ...
                'OutputActions',all_lights);
            SMA = sma.AddState(SMA,'Name','StartInterval','Timer',t.T_start, ...
                'StateChangeConditions',start_conditions,'OutputActions',after_q1_lights);
            SMA = sma.AddState(SMA,'Name','WaitForSecondPoke','Timer',t.T_second, ...
                'StateChangeConditions',{[q{2} 'In'],'SecondPoke','OtherIn','Violation','Tup','TrialTimeOut'}, ...
                'OutputActions',after_q1_lights);
            SMA = sma.AddState(SMA,'Name','SecondPoke','Timer',t.T_second_hold, ...
                'StateChangeConditions',second_conditions,'OutputActions',after_q2_lights);
            SMA = sma.AddState(SMA,'Name','WaitForThirdPoke','Timer',t.T_third, ...
                'StateChangeConditions',{[q{3} 'In'],'ThirdPoke','OtherIn','Violation','Tup','TrialTimeOut'}, ...
                'OutputActions',after_q2_lights);
            SMA = sma.AddState(SMA,'Name','ThirdPoke','Timer',t.T_third_hold, ...
                'StateChangeConditions',third_conditions,'OutputActions',q4_light);
            SMA = sma.AddState(SMA,'Name','WaitForFourthPoke','Timer',t.T_fourth, ...
                'StateChangeConditions',{[q{4} 'In'],'FourthPoke','OtherIn','Violation','Tup','TrialTimeOut'}, ...
                'OutputActions',q4_light);
            SMA = sma.AddState(SMA,'Name','FourthPoke','Timer',t.T_release, ...
                'StateChangeConditions',{'Tup','WaitForRewardPort','OtherIn','Violation'}, ...
                'OutputActions',{});
            SMA = sma.AddState(SMA,'Name','WaitForRewardPort','Timer',t.T_reward, ...
                'StateChangeConditions',{'BotCIn','RewardDelivery','OtherIn','Violation','Tup','TrialTimeOut'}, ...
                'OutputActions',{'BotCyellow',s.led_brightness});
            % GetValveTimes uses the active Bpod valve calibration. Valve 1 is BotC.
            valve_time = GetValveTimes(s.reward_ul,1);
            SMA = sma.AddState(SMA,'Name','RewardDelivery','Timer',valve_time, ...
                'StateChangeConditions',{'Tup','ITI'},'OutputActions',{'ValveState',1});
            SMA = sma.AddState(SMA,'Name','Violation','Timer',t.T_error, ...
                'StateChangeConditions',{'Tup','WaitForFirstPoke'},'OutputActions',{});
            SMA = sma.AddState(SMA,'Name','TrialTimeOut','Timer',t.T_timeout, ...
                'StateChangeConditions',{'Tup','ITI'},'OutputActions',{});
            SMA = sma.AddState(SMA,'Name','ITI','Timer',t.ITI, ...
                'StateChangeConditions',{'Tup','exit'},'OutputActions',{});
            obj.statematrix = SMA;
        end

        function trialCompleted(obj)
            if strcmp(obj.mode,'shaping')
                obj.shapingTrialCompleted();
                return;
            end
            p = obj.peh(end);
            ndt = obj.n_done_trials;
            [obj.poke_times,obj.poke_types] = ana.getAllPokes(p);
            hit_time = stt_all.firstEntry(p,'RewardDelivery');
            timeout_time = stt_all.firstEntry(p,'TrialTimeOut');
            % A behavioral trial begins only when the center port is poked.
            obj.trial_started = isfinite(stt_all.firstEntry(p,'StartInterval'));
            if obj.trial_started
                obj.counted_trials = obj.counted_trials + 1;
                obj.trial_number = obj.counted_trials;
            end
            if isfield(p.States,'Violation')
                visits = p.States.Violation;
                violation_times = visits(isfinite(visits(:,1)),1);
            else
                violation_times = [];
            end
            obj.restart_count = numel(violation_times);
            obj.wrong_poke_ports = cell(1,obj.restart_count);
            obj.wrong_poke_steps = NaN(1,obj.restart_count);
            for k = 1:obj.restart_count
                obj.wrong_poke_ports{k} = stt_all.pokeAtTime( ...
                    obj.poke_times,obj.poke_types,violation_times(k));
                obj.wrong_poke_steps(k) = stt_all.priorStep(p,violation_times(k));
                % A wrong port during an interval belongs to its upcoming step.
                error_step = NaN;
                if stt_all.endedAt(p,'StartInterval',violation_times(k)) || ...
                        stt_all.endedAt(p,'WaitForSecondPoke',violation_times(k))
                    error_step = 2;
                elseif stt_all.endedAt(p,'SecondPoke',violation_times(k)) || ...
                        stt_all.endedAt(p,'WaitForThirdPoke',violation_times(k))
                    error_step = 3;
                elseif stt_all.endedAt(p,'ThirdPoke',violation_times(k)) || ...
                        stt_all.endedAt(p,'WaitForFourthPoke',violation_times(k))
                    error_step = 4;
                end
                if ~isempty(obj.wrong_poke_ports{k}) && isfinite(error_step)
                    obj.error_count = obj.error_count + 1;
                    obj.error_poke_ports{end+1} = obj.wrong_poke_ports{k};
                    obj.error_poke_steps(end+1) = error_step;
                end
                if strcmp(obj.trial_phase,'B') && ~isempty(obj.wrong_poke_ports{k}) ...
                        && isfinite(error_step) ...
                        && strcmp(obj.wrong_poke_ports{k}, ...
                            obj.settings.sequence_A{error_step})
                    obj.a_consistent_error = true;
                end
            end
            if obj.restart_count>0
                obj.violation_port = obj.wrong_poke_ports{1};
                obj.violation_step = obj.wrong_poke_steps(1);
            end
            if isfinite(hit_time)
                if obj.restart_count>0
                    obj.outcome = 'hit_after_restart';
                else
                    obj.outcome = 'hit';
                end
                obj.hit = 1;
                obj.reward = obj.settings.reward_ul;
                obj.delivered_reward_ul = obj.reward;
                obj.choice = obj.target_sequence{4};
            elseif isfinite(timeout_time)
                if obj.trial_started
                    obj.outcome = 'timeout';
                else
                    obj.outcome = 'no_start';
                end
                obj.hit = 0;
                obj.viol = 0;
                obj.reward = 0;
                obj.timeout_state = stt_all.priorWait(p,timeout_time);
                obj.choice = 'timeout';
            else
                obj.outcome = 'incomplete';
                obj.hit = 0;
                obj.viol = 0;
                obj.reward = 0;
                obj.choice = 'incomplete';
            end
            obj.viol = double(obj.error_count>0);
            obj.clean_hit = obj.hit==1 && obj.restart_count==0;
            t1 = stt_all.lastEntry(p,'StartInterval');
            t2 = stt_all.lastEntry(p,'SecondPoke');
            t3 = stt_all.lastEntry(p,'ThirdPoke');
            t4 = stt_all.lastEntry(p,'FourthPoke');
            if isfinite(t1), obj.step_latency(1) = t1; end
            if isfinite(t1) && isfinite(t2), obj.step_latency(2) = t2-t1; end
            if isfinite(t2) && isfinite(t3), obj.step_latency(3) = t3-t2; end
            if isfinite(t3) && isfinite(t4), obj.step_latency(4) = t4-t3; end
            obj.RT = obj.step_latency(4);
            obj.hit_history(ndt) = obj.hit;
            obj.reward_history(ndt) = obj.reward;
            obj.violation_history(ndt) = obj.viol;
            obj.choice_history{ndt} = obj.choice;
            obj.RT_history(ndt) = obj.RT;
            if obj.trial_started && strcmp(obj.trial_phase,'A')
                obj.a_completed_trials = obj.a_completed_trials + 1;
                obj.a_hit_history(end+1) = obj.clean_hit;
                if stt_all.shouldSwitch(obj.settings,obj.a_completed_trials,obj.a_hit_history)
                    obj.phase = 'B';
                    obj.switch_after_trial = obj.trial_number;
                end
            elseif obj.trial_started
                obj.b_completed_trials = obj.b_completed_trials + 1;
            end
        end

        function useShapingSettings(obj,settings_name,expg_data,subj_data)
            if nargin < 2 || isempty(settings_name), settings_name = 'stt_shaping'; end
            if nargin < 3, expg_data = []; end
            if nargin < 4, subj_data = []; end
            s = struct();
            s.name = settings_name;
            % Shape the four-poke A sequence, one additional port per stage.
            s.sequence = {'MidC','BotL','MidL','TopR'};
            s.stage = obj.stage;               % default from the class property
            s.advance_mode = 'performance';   % 'manual' or 'performance'
            s.performance_min_trials_stage1 = 200;
            s.performance_min_trials_later = 100;
            s.performance_threshold = 0.95;
            s.T_first = 30;                   % stage 1 no-poke runs must end
            s.T_start_min = 0.1;
            s.T_start_max = 0.2;
            s.T_second = 10;
            s.T_second_hold = 0.1;            % provisional 100 ms q2 hold
            s.T_third = 10;
            s.T_third_hold = 0.1;             % provisional 100 ms q3 hold
            s.T_fourth = 10;
            s.T_fourth_hold = 0.1;            % provisional 100 ms q4 hold
            s.T_reward = 10;
            s.T_error = 0.2;
            s.T_timeout = 0.01;
            s.ITI_min = 0.5;
            s.ITI_max = 1.0;                  % sketches: 0.5-1 s jitter
            s.reward_ul = 5;                  % provisional; check calibration
            s.led_brightness = 255;
            s.reward_port_cue = true;         % BotC LED on in WaitForRewardPort
            % Restored between sessions only if explicitly supplied by the lab.
            s.stage_completed_trials = 0;
            s.stage_rewarded_trials = 0;
            s.stage_hit_history = [];
            s.stage_advance_trials = [];
            if ~isempty(expg_data), s = utils.apply_struct(s,expg_data); end
            if ~isempty(subj_data), s = utils.apply_struct(s,subj_data); end
            if obj.prompt_mode
                s.stage = stt_all.promptStage();
            end
            % A session is one training day: do not carry its denominator
            % into the following day's performance calculation.
            s.stage_completed_trials = 0;
            s.stage_rewarded_trials = 0;
            s.stage_hit_history = [];
            stt_all.validateShapingSettings(s);
            obj.settings = s;
            obj.stage = s.stage;
            obj.stage_completed_trials = s.stage_completed_trials;
            obj.stage_rewarded_trials = s.stage_rewarded_trials;
            obj.stage_hit_history = s.stage_hit_history;
            obj.stage_advance_trials = s.stage_advance_trials;
            obj.pending_training = false;
            obj.daily_evaluated = false;
            obj.stage_performance = NaN;
            fprintf('STT shaping session: stage %d, advance mode %s.\n', ...
                obj.stage,s.advance_mode);
        end

        function prepareShapingTrial(obj)
            s = obj.settings;
            obj.trial_stage = obj.stage;
            obj.target_sequence = s.sequence(1:obj.stage);
            fprintf('STT shaping trial %d (stage %d): %s, then BotC.\n', ...
                obj.n_started_trials,obj.stage,strjoin(obj.target_sequence,' -> '));
            obj.trial_timing = struct('T_first',s.T_first, ...
                'T_start',stt_all.jitter(s.T_start_min,s.T_start_max), ...
                'T_second',s.T_second,'T_second_hold',s.T_second_hold, ...
                'T_third',s.T_third,'T_third_hold',s.T_third_hold, ...
                'T_fourth',s.T_fourth,'T_fourth_hold',s.T_fourth_hold, ...
                'T_reward',s.T_reward,'T_error',s.T_error, ...
                'T_timeout',s.T_timeout,'ITI',stt_all.jitter(s.ITI_min,s.ITI_max));
            obj.outcome = '';
            obj.violation_port = '';
            obj.violation_step = NaN;
            obj.timeout_state = '';
            obj.restart_count = 0;
            obj.hold_break_count = [0 0 0];
            obj.trial_started = false;
            obj.trial_number = NaN;
            obj.stage_trial_number = NaN;
            obj.poke_times = [];
            obj.poke_types = {};
            obj.step_latency = [NaN NaN NaN NaN NaN];
            obj.delivered_reward_ul = 0;
        end

        function SMA = generateShapingSM(obj)
            s = obj.settings;
            t = obj.trial_timing;
            q = obj.target_sequence;
            n = numel(q);
            b = s.led_brightness;
            lights = cellfun(@(p)stt_all.ledActions({p},b),q,'UniformOutput',false);
            % Register every PortArray pattern before AddState maps LED aliases.
            SMA = sma.newStateMachine(lights);

            % State that follows each completed step.
            after = {'WaitForSecondPoke','WaitForThirdPoke', ...
                'WaitForFourthPoke','WaitForRewardPort'};
            after{n} = 'WaitForRewardPort';

            % --- q1: start poke (all stages) ---
            first_conditions = {[q{1} 'In'],'StartInterval'};
            first_timer = 0;   % no Tup transition -> waits indefinitely
            if s.T_first > 0
                first_conditions = [first_conditions,{'Tup','TrialTimeOut'}];
                first_timer = t.T_first;
            end
            SMA = sma.AddState(SMA,'Name','WaitForFirstPoke','Timer',first_timer, ...
                'StateChangeConditions',first_conditions,'OutputActions',lights{1});
            SMA = sma.AddState(SMA,'Name','StartInterval','Timer',t.T_start, ...
                'StateChangeConditions',{[q{1} 'Out'],'WaitForFirstPoke','Tup',after{1}}, ...
                'OutputActions',lights{1});

            % --- q2: second port with hold (stages 2-4) ---
            if n >= 2
                SMA = sma.AddState(SMA,'Name','WaitForSecondPoke','Timer',t.T_second, ...
                    'StateChangeConditions',{[q{2} 'In'],'SecondPoke','OtherIn','Violation', ...
                    'Tup','TrialTimeOut'},'OutputActions',lights{2});
                SMA = sma.AddState(SMA,'Name','SecondPoke','Timer',t.T_second_hold, ...
                    'StateChangeConditions',{[q{2} 'Out'],'WaitForSecondPoke','Tup',after{2}}, ...
                    'OutputActions',lights{2});
            end

            % --- q3: third port with hold (stages 3-4) ---
            if n >= 3
                SMA = sma.AddState(SMA,'Name','WaitForThirdPoke','Timer',t.T_third, ...
                    'StateChangeConditions',{[q{3} 'In'],'ThirdPoke','OtherIn','Violation', ...
                    'Tup','TrialTimeOut'},'OutputActions',lights{3});
                SMA = sma.AddState(SMA,'Name','ThirdPoke','Timer',t.T_third_hold, ...
                    'StateChangeConditions',{[q{3} 'Out'],'WaitForThirdPoke','Tup',after{3}}, ...
                    'OutputActions',lights{3});
            end

            % --- q4: fourth port with hold (stage 4) ---
            if n >= 4
                SMA = sma.AddState(SMA,'Name','WaitForFourthPoke','Timer',t.T_fourth, ...
                    'StateChangeConditions',{[q{4} 'In'],'FourthPoke','OtherIn','Violation', ...
                    'Tup','TrialTimeOut'},'OutputActions',lights{4});
                SMA = sma.AddState(SMA,'Name','FourthPoke','Timer',t.T_fourth_hold, ...
                    'StateChangeConditions',{[q{4} 'Out'],'WaitForFourthPoke','Tup',after{4}}, ...
                    'OutputActions',lights{4});
            end

            % --- reward port (all stages) ---
            reward_cue = {};
            if s.reward_port_cue, reward_cue = {'BotCyellow',b}; end
            SMA = sma.AddState(SMA,'Name','WaitForRewardPort','Timer',t.T_reward, ...
                'StateChangeConditions',{'BotCIn','RewardDelivery','Tup','TrialTimeOut'}, ...
                'OutputActions',reward_cue);
            % GetValveTimes uses the active Bpod valve calibration. Valve 1 is BotC.
            valve_time = GetValveTimes(s.reward_ul,1);
            SMA = sma.AddState(SMA,'Name','RewardDelivery','Timer',valve_time, ...
                'StateChangeConditions',{'Tup','ITI'},'OutputActions',{'ValveState',1});

            % --- outcomes ---
            if n >= 2
                SMA = sma.AddState(SMA,'Name','Violation','Timer',t.T_error, ...
                    'StateChangeConditions',{'Tup','ITI'},'OutputActions',{});
            end
            SMA = sma.AddState(SMA,'Name','TrialTimeOut','Timer',t.T_timeout, ...
                'StateChangeConditions',{'Tup','ITI'},'OutputActions',{});
            SMA = sma.AddState(SMA,'Name','ITI','Timer',t.ITI, ...
                'StateChangeConditions',{'Tup','exit'},'OutputActions',{});
            obj.statematrix = SMA;
        end

        function shapingTrialCompleted(obj)
            p = obj.peh(end);
            ndt = obj.n_done_trials;
            [obj.poke_times,obj.poke_types] = ana.getAllPokes(p);
            hit_time = stt_all.firstEntry(p,'RewardDelivery');
            timeout_time = stt_all.firstEntry(p,'TrialTimeOut');
            violation_time = stt_all.firstEntry(p,'Violation');

            obj.restart_count = max(stt_all.nEntries(p,'StartInterval')-1,0);
            obj.hold_break_count = [ ...
                max(stt_all.nEntries(p,'WaitForSecondPoke')-1,0), ...
                max(stt_all.nEntries(p,'WaitForThirdPoke')-1,0), ...
                max(stt_all.nEntries(p,'WaitForFourthPoke')-1,0)];

            obj.reward = 0;
            obj.hit = 0;
            obj.viol = 0;
            if isfinite(hit_time)
                obj.outcome = 'hit';
                obj.hit = 1;
                obj.reward = obj.settings.reward_ul;
                obj.choice = 'BotC';
            elseif isfinite(violation_time)
                obj.outcome = 'violation';
                obj.viol = 1;
                obj.violation_port = stt_all.pokeAtTime( ...
                    obj.poke_times,obj.poke_types,violation_time);
                obj.violation_step = stt_all.priorStep(p,violation_time);
                obj.choice = obj.violation_port;
            elseif isfinite(timeout_time)
                obj.outcome = 'timeout';
                obj.timeout_state = stt_all.priorWait(p,timeout_time);
                obj.choice = 'timeout';
            else
                obj.outcome = 'incomplete';
                obj.choice = 'incomplete';
            end
            obj.delivered_reward_ul = obj.reward;

            % Stage 1 counts the opportunity when the first LED state starts.
            % Later stages count only after the center-port start poke.
            if obj.trial_stage == 1
                obj.trial_started = stt_all.nEntries(p,'WaitForFirstPoke') > 0;
            else
                obj.trial_started = isfinite(stt_all.firstEntry(p,'StartInterval'));
            end

            % Latencies: q1 from trial start; each later step from the previous one.
            t1 = stt_all.lastEntry(p,'StartInterval');
            t2 = stt_all.lastEntry(p,'SecondPoke');
            t3 = stt_all.lastEntry(p,'ThirdPoke');
            t4 = stt_all.lastEntry(p,'FourthPoke');
            tr = stt_all.lastEntry(p,'WaitForRewardPort');
            obj.step_latency(1) = t1;
            obj.step_latency(2) = t2-t1;
            obj.step_latency(3) = t3-t2;
            obj.step_latency(4) = t4-t3;
            obj.step_latency(5) = hit_time-tr;
            obj.RT = obj.step_latency(5);

            obj.hit_history(ndt) = obj.hit;
            obj.reward_history(ndt) = obj.reward;
            obj.violation_history(ndt) = obj.viol;
            obj.choice_history{ndt} = obj.choice;
            obj.RT_history(ndt) = obj.RT;

            % Accumulate today's numerator and denominator. Evaluate once
            % when endSession is called, after the final trial is saved.
            if obj.trial_started
                obj.stage_completed_trials = obj.stage_completed_trials + 1;
                obj.stage_rewarded_trials = obj.stage_rewarded_trials + obj.hit;
                obj.stage_hit_history(end+1) = obj.hit;
                obj.stage_trial_number = obj.stage_completed_trials;
                obj.trial_number = obj.stage_completed_trials;
            end
        end

        function endSession(obj)
            if strcmp(obj.mode,'shaping') && ~obj.daily_evaluated
                obj.daily_evaluated = true;
                if obj.stage_completed_trials > 0
                    obj.stage_performance = ...
                        obj.stage_rewarded_trials / obj.stage_completed_trials;
                end
                min_trials = obj.settings.performance_min_trials_later;
                if obj.stage == 1
                    min_trials = obj.settings.performance_min_trials_stage1;
                end
                fprintf('STT shaping day: stage %d, rewarded %d/%d, performance %.1f%% (minimum %d trials).\n', ...
                    obj.stage,obj.stage_rewarded_trials,obj.stage_completed_trials, ...
                    100*obj.stage_performance,min_trials);
                if stt_all.criterionMet(obj.settings, ...
                        obj.stage_completed_trials,obj.stage_rewarded_trials,min_trials)
                    if obj.stage < 4
                        obj.stage = obj.stage + 1;
                        obj.stage_advance_trials(end+1) = obj.n_done_trials;
                        fprintf('STT shaping: next session starts at stage %d.\n',obj.stage);
                    elseif ~obj.shaping_complete
                        obj.shaping_complete = true;
                        obj.pending_training = true;
                        fprintf('STT shaping: next session starts with training A.\n');
                    end
                end
            end
            endSession@proto.ProtoObj(obj);
        end

        function list = trialPropertiesToSave(obj)
            if strcmp(obj.mode,'shaping')
                list = [trialPropertiesToSave@proto.ProtoObj(obj); ...
                    {'mode';'trial_stage';'target_sequence';'trial_started';'trial_number'; ...
                     'stage_completed_trials';'stage_rewarded_trials'; ...
                     'stage_trial_number'; ...
                     'trial_timing';'outcome';'violation_port';'violation_step'; ...
                     'timeout_state';'restart_count';'hold_break_count'; ...
                     'poke_times';'poke_types';'step_latency';'delivered_reward_ul'}];
                return;
            end
            list = [trialPropertiesToSave@proto.ProtoObj(obj); ...
                {'mode';'trial_phase';'b_condition';'target_sequence';'trial_since_switch'; ...
                 'a_completed_trials';'b_completed_trials';'switch_after_trial';'trial_timing';'outcome'; ...
                 'violation_port';'violation_step';'timeout_state';'a_consistent_error'; ...
                 'restart_count';'wrong_poke_ports';'wrong_poke_steps';'clean_hit'; ...
                 'trial_started';'trial_number';'counted_trials'; ...
                 'error_count';'error_poke_ports';'error_poke_steps'; ...
                 'poke_times';'poke_types';'step_latency';'delivered_reward_ul'}];
        end

        function list = sessionPropertiesToSave(obj)
            if strcmp(obj.mode,'shaping')
                list = [sessionPropertiesToSave@proto.ProtoObj(obj); ...
                    {'mode';'stage';'stage_completed_trials';'stage_rewarded_trials'; ...
                     'stage_performance';'daily_evaluated'; ...
                     'stage_hit_history';'stage_advance_trials'; ...
                     'shaping_complete';'pending_training'}];
                return;
            end
            list = [sessionPropertiesToSave@proto.ProtoObj(obj); ...
                {'mode';'phase';'b_condition';'a_completed_trials';'b_completed_trials';'counted_trials'; ...
                 'a_hit_history';'switch_after_trial'}];
        end

        function next_settings = prepareNextSession(obj)
            if strcmp(obj.mode,'shaping')
                if obj.pending_training
                    next_settings = struct('mode','train','prompt_mode',false, ...
                        'prompt_session',false,'run_mode','A_only');
                    return;
                end
                next_settings = struct('mode',obj.mode,'prompt_mode',false, ...
                    'stage',obj.stage,'advance_mode',obj.settings.advance_mode, ...
                    'performance_min_trials_stage1',obj.settings.performance_min_trials_stage1, ...
                    'performance_min_trials_later',obj.settings.performance_min_trials_later, ...
                    'performance_threshold',obj.settings.performance_threshold, ...
                    'stage_completed_trials',0,'stage_rewarded_trials',0, ...
                    'stage_hit_history',[], ...
                    'stage_advance_trials',obj.stage_advance_trials);
                return;
            end
            next_settings = struct('mode','train','prompt_mode',false, ...
                'prompt_session',false,'run_mode',obj.settings.run_mode, ...
                'phase',obj.phase,'b_condition',obj.b_condition, ...
                'a_completed_trials',obj.a_completed_trials, ...
                'b_completed_trials',obj.b_completed_trials, ...
                'a_hit_history',obj.a_hit_history, ...
                'switch_after_trial',obj.switch_after_trial);
        end
    end

    methods (Static, Access = private)
        function mode = promptMode()
            fprintf('\nSTT protocol: 1 = shaping, 2 = train.\n');
            while true
                answer = strtrim(input('Choose 1 or 2: ','s'));
                if strcmp(answer,'1'), mode = 'shaping'; return; end
                if strcmp(answer,'2'), mode = 'train'; return; end
                fprintf('Please enter 1 or 2.\n');
            end
        end

        function stage = promptStage()
            while true
                answer = strtrim(input('Shaping stage (1, 2, 3, or 4): ','s'));
                stage = str2double(answer);
                if isfinite(stage) && ismember(stage,1:4), return; end
                fprintf('Please enter 1, 2, 3, or 4.\n');
            end
        end

        function validateShapingSettings(s)
            ports = setdiff(int.getPokeList(),{'BotC'},'stable');
            q = s.sequence;
            assert(iscell(q) && all(cellfun(@ischar,q)) && numel(q)==4 ...
                && numel(unique(q))==4 && all(ismember(q,ports)) ...
                && strcmp(q{1},'MidC'), ...
                'stt_shaping:Settings', ...
                'sequence must start at MidC and have four distinct nonreward ports.');
            assert(isnumeric(s.stage) && isscalar(s.stage) && ismember(s.stage,1:4), ...
                'stt_shaping:Settings','stage must be 1, 2, 3, or 4.');
            assert(ismember(s.advance_mode,{'manual','performance'}), ...
                'stt_shaping:Settings','advance_mode must be manual or performance.');
            if strcmp(s.advance_mode,'performance')
                assert(s.performance_min_trials_stage1>=1 ...
                    && mod(s.performance_min_trials_stage1,1)==0 ...
                    && s.performance_min_trials_later>=1 ...
                    && mod(s.performance_min_trials_later,1)==0 ...
                    && s.performance_threshold>0 && s.performance_threshold<=1, ...
                    'stt_shaping:Settings','Invalid performance criterion.');
            end
            pairs = {'T_start_min','T_start_max';'ITI_min','ITI_max'};
            for k=1:size(pairs,1)
                assert(s.(pairs{k,1})>0 && s.(pairs{k,2})>=s.(pairs{k,1}), ...
                    'stt_shaping:Settings','Invalid timer range %s/%s.',pairs{k,1},pairs{k,2});
            end
            assert(isnumeric(s.T_first) && isscalar(s.T_first) && isfinite(s.T_first) ...
                && s.T_first>=0, 'stt_shaping:Settings', ...
                'T_first must be 0 (no timeout) or a positive finite scalar.');
            positive = {'T_second','T_second_hold','T_third','T_third_hold', ...
                'T_fourth','T_fourth_hold', ...
                'T_reward','T_error','T_timeout','reward_ul'};
            for k=1:numel(positive)
                v = s.(positive{k});
                assert(isnumeric(v) && isscalar(v) && isfinite(v) && v>0, ...
                    'stt_shaping:Settings','%s must be a positive finite scalar.',positive{k});
            end
            assert(isnumeric(s.led_brightness) && isscalar(s.led_brightness) ...
                && s.led_brightness>=2 && s.led_brightness<=255, ...
                'stt_shaping:Settings','led_brightness must be an integer from 2 to 255.');
            assert(s.stage_completed_trials>=0 && mod(s.stage_completed_trials,1)==0 ...
                && s.stage_rewarded_trials>=0 ...
                && s.stage_rewarded_trials<=s.stage_completed_trials ...
                && numel(s.stage_hit_history)<=s.stage_completed_trials, ...
                'stt_shaping:Settings','Restored hit history exceeds completed stage trials.');
        end

        function yes = criterionMet(s,n,rewarded,min_trials)
            yes = strcmp(s.advance_mode,'performance') ...
                && n>=min_trials ...
                && rewarded/n>=s.performance_threshold;
        end

        function n = nEntries(p,name)
            n = 0;
            if isfield(p.States,name)
                v = p.States.(name);
                if ~isempty(v), n = sum(isfinite(v(:,1))); end
            end
        end

        function s = promptRunMode(s)
            fprintf('\nSTT session setup (one choice for this MATLAB run):\n');
            fprintf('  1 = A only\n  2 = B only\n  3 = A then B after N completed A trials\n');
            while true
                answer = strtrim(input('Choose 1, 2, or 3: ','s'));
                if any(strcmp(answer,{'1','2','3'})), break; end
                fprintf('Please enter 1, 2, or 3.\n');
            end
            switch answer
                case '1'
                    s.run_mode = 'A_only';
                case '2'
                    s.run_mode = 'B_only';
                case '3'
                    s.run_mode = 'switch';
            end
            if ~strcmp(s.run_mode,'A_only')
                fprintf('B condition: 1 = similar, 2 = y-axis mirror, 3 = different.\n');
                while true
                    choice = strtrim(input('Choose B condition (1, 2, or 3): ','s'));
                    if any(strcmp(choice,{'1','2','3'})), break; end
                    fprintf('Please enter 1, 2, or 3.\n');
                end
                s.b_condition = ['B' choice];
            end
            if strcmp(s.run_mode,'switch')
                while true
                    answer = strtrim(input( ...
                        'Switch after how many completed A trials? ','s'));
                    n = str2double(answer);
                    if isfinite(n) && n>=1 && mod(n,1)==0, break; end
                    fprintf('Please enter a positive whole number.\n');
                end
                s.a_trial_count = n;
            end
        end

        function s = configureRunMode(s)
            switch s.run_mode
                case 'A_only'
                    s.phase = 'A';
                    s.switch_mode = 'manual';
                    s.a_trial_count = 0;
                case 'B_only'
                    s.phase = 'B';
                    s.switch_mode = 'manual';
                    s.a_trial_count = 0;
                case 'switch'
                    s.phase = 'A';
                    s.switch_mode = 'fixed';
                otherwise
                    error('stt:Settings', ...
                        'run_mode must be A_only, B_only, or switch.');
            end
        end

        function validateSettings(s)
            ports = setdiff(int.getPokeList(),{'BotC'},'stable');
            names = {'sequence_A','sequence_B1','sequence_B2','sequence_B3'};
            for k = 1:numel(names)
                q = s.(names{k});
                assert(iscell(q) && all(cellfun(@ischar,q)) && numel(q)==4 ...
                    && numel(unique(q))==4 ...
                    && all(ismember(q,ports)), ...
                    'stt:Settings','%s must have four distinct nonreward port aliases.',names{k});
            end
            assert(all(cellfun(@(q)strcmp(q{1},'MidC'), ...
                {s.sequence_A,s.sequence_B1,s.sequence_B2,s.sequence_B3})), ...
                'stt:Settings','Every sequence must start at MidC.');
            assert(isequal(s.sequence_A(1:2),s.sequence_B1(1:2)) && ...
                ~strcmp(s.sequence_A{3},s.sequence_B1{3}) && ...
                ~strcmp(s.sequence_A{4},s.sequence_B1{4}), ...
                'stt:Settings','B1 must share the first two ports and change q3/q4.');
            mirror = containers.Map({'MidR','TopR','BotR','MidC','TopL','BotL','MidL'}, ...
                                    {'MidL','TopL','BotL','MidC','TopR','BotR','MidR'});
            expected = cellfun(@(p)mirror(p),s.sequence_A,'UniformOutput',false);
            assert(isequal(s.sequence_B2,expected), ...
                'stt:Settings','B2 must be the y-axis mirror of A.');
            assert(isempty(intersect(s.sequence_A(2:4),s.sequence_B3(2:4))), ...
                'stt:Settings','B3 must share no peripheral ports with A.');
            assert(ismember(s.b_condition,{'B1','B2','B3'}), ...
                'stt:Settings','b_condition must be B1, B2 or B3.');
            assert(islogical(s.prompt_session) && isscalar(s.prompt_session), ...
                'stt:Settings','prompt_session must be true or false.');
            assert(ismember(s.switch_mode,{'manual','fixed','performance'}), ...
                'stt:Settings','switch_mode must be manual, fixed or performance.');
            assert(ismember(s.phase,{'A','B'}), 'stt:Settings','phase must be A or B.');
            assert(ismember(s.early_start_policy,{'restart','violation','ignore'}) ...
                && ismember(s.early_second_policy,{'retry','violation','ignore'}), ...
                'stt:Settings','Invalid early-poke policy.');
            pairs = {'T_start_min','T_start_max';'ITI_min','ITI_max'};
            for k=1:size(pairs,1)
                assert(s.(pairs{k,1})>0 && s.(pairs{k,2})>=s.(pairs{k,1}), ...
                    'stt:Settings','Invalid timer range %s/%s.',pairs{k,1},pairs{k,2});
            end
            positive = {'T_first','T_second','T_second_hold','T_release', ...
                'T_third','T_third_hold','T_fourth', ...
                'T_reward','T_error','T_timeout','reward_ul'};
            for k=1:numel(positive)
                v = s.(positive{k});
                assert(isnumeric(v) && isscalar(v) && isfinite(v) && v>0, ...
                    'stt:Settings','%s must be a positive finite scalar.',positive{k});
            end
            assert(isnumeric(s.led_brightness) && isscalar(s.led_brightness) ...
                && s.led_brightness>=2 && s.led_brightness<=255, ...
                'stt:Settings','led_brightness must be an integer from 2 to 255.');
            assert(isnumeric(s.a_trial_count) && isscalar(s.a_trial_count) ...
                && isfinite(s.a_trial_count) && s.a_trial_count>=0 ...
                && mod(s.a_trial_count,1)==0, ...
                'stt:Settings','a_trial_count must be a nonnegative integer.');
            if strcmp(s.switch_mode,'fixed')
                assert(s.a_trial_count>=1,'stt:Settings', ...
                    'Fixed switching requires a_trial_count >= 1.');
            elseif strcmp(s.switch_mode,'performance')
                assert(s.performance_min_trials>=1 && mod(s.performance_min_trials,1)==0 ...
                    && s.performance_window>=1 && mod(s.performance_window,1)==0 ...
                    && s.performance_threshold>0 && s.performance_threshold<=1, ...
                    'stt:Settings','Invalid performance switch criterion.');
            end
            assert(s.a_completed_trials>=0 && mod(s.a_completed_trials,1)==0 ...
                && s.b_completed_trials>=0 && mod(s.b_completed_trials,1)==0 ...
                && numel(s.a_hit_history)<=s.a_completed_trials, ...
                'stt:Settings','Restored A history exceeds completed A trials.');
            if strcmp(s.phase,'A') && strcmp(s.switch_mode,'performance')
                assert(numel(s.a_hit_history)==s.a_completed_trials, ...
                    'stt:Settings','Performance switching requires full A history.');
            end
        end

        function a = ledActions(ports,brightness)
            a = cell(1,2*numel(ports));
            for k=1:numel(ports)
                a{2*k-1} = [ports{k} 'yellow'];
                a{2*k} = brightness;
            end
        end

        function t = jitter(a,b)
            t = a+(b-a)*rand();
        end

        function yes = shouldSwitch(s,n,h)
            if strcmp(s.switch_mode,'fixed')
                yes = n>=s.a_trial_count;
            elseif strcmp(s.switch_mode,'performance')
                yes = n>=max(s.performance_min_trials,s.performance_window) ...
                    && mean(h(end-s.performance_window+1:end))>=s.performance_threshold;
            else
                yes = false;
            end
        end

        function t = firstEntry(p,name)
            t = NaN;
            if isfield(p.States,name)
                v = p.States.(name);
                if ~isempty(v)
                    ix = find(isfinite(v(:,1)),1,'first');
                    if ~isempty(ix), t = v(ix,1); end
                end
            end
        end

        function t = lastEntry(p,name)
            t = NaN;
            if isfield(p.States,name)
                v = p.States.(name);
                if ~isempty(v)
                    ix = find(isfinite(v(:,1)),1,'last');
                    if ~isempty(ix), t = v(ix,1); end
                end
            end
        end

        function step = priorStep(p,t)
            step = NaN;
            waits = {'WaitForFirstPoke','WaitForSecondPoke', ...
                     'WaitForThirdPoke','WaitForFourthPoke','WaitForRewardPort'};
            for k=1:numel(waits)
                if stt_all.endedAt(p,waits{k},t), step = k; return; end
            end
            if stt_all.endedAt(p,'StartInterval',t), step=1; return; end
            if stt_all.endedAt(p,'SecondPoke',t), step=2; return; end
            if stt_all.endedAt(p,'ThirdPoke',t), step=3; return; end
            if stt_all.endedAt(p,'FourthPoke',t), step=4; end
        end

        function name = priorWait(p,t)
            name = '';
            waits = {'WaitForFirstPoke','WaitForSecondPoke', ...
                     'WaitForThirdPoke','WaitForFourthPoke','WaitForRewardPort'};
            for k=1:numel(waits)
                if stt_all.endedAt(p,waits{k},t), name=waits{k}; return; end
            end
        end

        function yes = endedAt(p,name,t)
            yes = false;
            if ~isfield(p.States,name), return; end
            v = p.States.(name);
            if ~isempty(v), yes = any(isfinite(v(:,2)) & abs(v(:,2)-t)<0.02); end
        end

        function port = pokeAtTime(times,types,t)
            port = '';
            if isempty(times), return; end
            ix = find(abs(times-t)<0.02,1,'last');
            if isempty(ix), return; end
            event = types{ix};
            if numel(event)>2 && strcmpi(event(end-1:end),'In')
                port = event(1:end-2);
            end
        end
    end
end
