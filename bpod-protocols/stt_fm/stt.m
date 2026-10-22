classdef stt < proto.ProtoObj
    % Sequence Transfer Task. One Bpod state matrix is generated per trial.
    % All timings and port assignments below are provisional test settings.

    properties
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
        step_latency = [NaN NaN NaN]
        delivered_reward_ul = 0
    end

    methods
        function [x,y] = init(obj,varargin)
            [x,y] = init@proto.ProtoObj(obj,varargin{:});
            obj.trial_time_limit = 400;
        end

        function useSettings(obj,settings_name,expg_data,subj_data)
            if nargin < 2 || isempty(settings_name), settings_name = 'stt'; end
            if nargin < 3, expg_data = []; end
            if nargin < 4, subj_data = []; end
            s = struct();
            s.name = settings_name;
            % Illustrative port assignments. Replace after checking the rig layout.
            s.sequence_A = {'MidC','TopR','BotR'};
            s.sequence_B1 = {'MidC','MidR','MidL'}; % q2/q3 share no A ports
            s.sequence_B2 = {'MidC','TopR','MidR'}; % shared q1/q2, changed q3
            s.sequence_B3 = {'MidC','TopL','BotL'}; % left-right mirror of A
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
            s.T_release = 0.01;           % brief transition after q3
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
                s = stt.promptRunMode(s);
                % The prompted switch trial is counted within this session.
                s.a_completed_trials = 0;
                s.b_completed_trials = 0;
                s.a_hit_history = [];
                s.switch_after_trial = NaN;
            end
            s = stt.configureRunMode(s);
            stt.validateSettings(s);
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
            s = obj.settings;
            obj.trial_phase = obj.phase;
            if strcmp(obj.phase,'A')
                obj.target_sequence = s.sequence_A;
                obj.trial_since_switch = 0;
            else
                obj.target_sequence = s.(['sequence_' s.b_condition]);
                obj.trial_since_switch = obj.b_completed_trials + 1;
            end
            fprintf('STT trial %d: %s -> %s -> %s, then BotC.\n', ...
                obj.n_started_trials,obj.target_sequence{:});
            obj.trial_timing = struct('T_first',s.T_first, ...
                'T_start',stt.jitter(s.T_start_min,s.T_start_max), ...
                'T_second',s.T_second,'T_second_hold',s.T_second_hold, ...
                'T_release',s.T_release,'T_third',s.T_third, ...
                'T_reward',s.T_reward,'T_error',s.T_error, ...
                'T_timeout',s.T_timeout,'ITI',stt.jitter(s.ITI_min,s.ITI_max));
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
            obj.step_latency = [NaN NaN NaN];
            obj.delivered_reward_ul = 0;
        end

        function SMA = generateSM(obj)
            s = obj.settings;
            t = obj.trial_timing;
            q = obj.target_sequence;
            all_lights = stt.ledActions(q,s.led_brightness);
            after_q1_lights = stt.ledActions(q(2:3),s.led_brightness);
            q3_light = stt.ledActions(q(3),s.led_brightness);
            % Register every PortArray pattern before AddState maps LED aliases.
            SMA = sma.newStateMachine({all_lights,after_q1_lights,q3_light});

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

            SMA = sma.AddState(SMA,'Name','WaitForFirstPoke','Timer',t.T_first, ...
                'StateChangeConditions',{[q{1} 'In'],'StartInterval','OtherIn','Violation','Tup','TrialTimeOut'}, ...
                'OutputActions',all_lights);
            SMA = sma.AddState(SMA,'Name','StartInterval','Timer',t.T_start, ...
                'StateChangeConditions',start_conditions,'OutputActions',after_q1_lights);
            SMA = sma.AddState(SMA,'Name','WaitForSecondPoke','Timer',t.T_second, ...
                'StateChangeConditions',{[q{2} 'In'],'SecondPoke','OtherIn','Violation','Tup','TrialTimeOut'}, ...
                'OutputActions',after_q1_lights);
            SMA = sma.AddState(SMA,'Name','SecondPoke','Timer',t.T_second_hold, ...
                'StateChangeConditions',second_conditions,'OutputActions',q3_light);
            SMA = sma.AddState(SMA,'Name','WaitForThirdPoke','Timer',t.T_third, ...
                'StateChangeConditions',{[q{3} 'In'],'ThirdPoke','OtherIn','Violation','Tup','TrialTimeOut'}, ...
                'OutputActions',q3_light);
            SMA = sma.AddState(SMA,'Name','ThirdPoke','Timer',t.T_release, ...
                'StateChangeConditions',{'Tup','WaitForRewardPort','OtherIn','Violation'},'OutputActions',{});
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
            p = obj.peh(end);
            ndt = obj.n_done_trials;
            [obj.poke_times,obj.poke_types] = ana.getAllPokes(p);
            hit_time = stt.firstEntry(p,'RewardDelivery');
            timeout_time = stt.firstEntry(p,'TrialTimeOut');
            % A behavioral trial begins only when the center port is poked.
            obj.trial_started = isfinite(stt.firstEntry(p,'StartInterval'));
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
                obj.wrong_poke_ports{k} = stt.pokeAtTime( ...
                    obj.poke_times,obj.poke_types,violation_times(k));
                obj.wrong_poke_steps(k) = stt.priorStep(p,violation_times(k));
                % A wrong port during an interval belongs to its upcoming step.
                error_step = NaN;
                if stt.endedAt(p,'StartInterval',violation_times(k)) || ...
                        stt.endedAt(p,'WaitForSecondPoke',violation_times(k))
                    error_step = 2;
                elseif stt.endedAt(p,'SecondPoke',violation_times(k)) || ...
                        stt.endedAt(p,'WaitForThirdPoke',violation_times(k))
                    error_step = 3;
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
                obj.choice = obj.target_sequence{3};
            elseif isfinite(timeout_time)
                if obj.trial_started
                    obj.outcome = 'timeout';
                else
                    obj.outcome = 'no_start';
                end
                obj.hit = 0;
                obj.viol = 0;
                obj.reward = 0;
                obj.timeout_state = stt.priorWait(p,timeout_time);
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
            t1 = stt.lastEntry(p,'StartInterval');
            t2 = stt.lastEntry(p,'SecondPoke');
            t3 = stt.lastEntry(p,'ThirdPoke');
            if isfinite(t1), obj.step_latency(1) = t1; end
            if isfinite(t1) && isfinite(t2), obj.step_latency(2) = t2-t1; end
            if isfinite(t2) && isfinite(t3), obj.step_latency(3) = t3-t2; end
            obj.RT = obj.step_latency(3);
            obj.hit_history(ndt) = obj.hit;
            obj.reward_history(ndt) = obj.reward;
            obj.violation_history(ndt) = obj.viol;
            obj.choice_history{ndt} = obj.choice;
            obj.RT_history(ndt) = obj.RT;
            if obj.trial_started && strcmp(obj.trial_phase,'A')
                obj.a_completed_trials = obj.a_completed_trials + 1;
                obj.a_hit_history(end+1) = obj.clean_hit;
                if stt.shouldSwitch(obj.settings,obj.a_completed_trials,obj.a_hit_history)
                    obj.phase = 'B';
                    obj.switch_after_trial = obj.trial_number;
                end
            elseif obj.trial_started
                obj.b_completed_trials = obj.b_completed_trials + 1;
            end
        end

        function list = trialPropertiesToSave(obj)
            list = [trialPropertiesToSave@proto.ProtoObj(obj); ...
                {'trial_phase';'b_condition';'target_sequence';'trial_since_switch'; ...
                 'a_completed_trials';'b_completed_trials';'switch_after_trial';'trial_timing';'outcome'; ...
                 'violation_port';'violation_step';'timeout_state';'a_consistent_error'; ...
                 'restart_count';'wrong_poke_ports';'wrong_poke_steps';'clean_hit'; ...
                 'trial_started';'trial_number';'counted_trials'; ...
                 'error_count';'error_poke_ports';'error_poke_steps'; ...
                 'poke_times';'poke_types';'step_latency';'delivered_reward_ul'}];
        end

        function list = sessionPropertiesToSave(obj)
            list = [sessionPropertiesToSave@proto.ProtoObj(obj); ...
                {'phase';'b_condition';'a_completed_trials';'b_completed_trials';'counted_trials'; ...
                 'a_hit_history';'switch_after_trial'}];
        end

        function next_settings = prepareNextSession(obj)
            next_settings = struct('phase',obj.phase,'b_condition',obj.b_condition, ...
                'a_completed_trials',obj.a_completed_trials, ...
                'b_completed_trials',obj.b_completed_trials, ...
                'a_hit_history',obj.a_hit_history, ...
                'switch_after_trial',obj.switch_after_trial);
        end
    end

    methods (Static, Access = private)
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
                fprintf('B condition: 1 = B1, 2 = B2, 3 = B3.\n');
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
                assert(iscell(q) && all(cellfun(@ischar,q)) && numel(q)==3 ...
                    && numel(unique(q))==3 ...
                    && all(ismember(q,ports)), ...
                    'stt:Settings','%s must have three distinct nonreward port aliases.',names{k});
            end
            assert(all(cellfun(@(q)strcmp(q{1},'MidC'), ...
                {s.sequence_A,s.sequence_B1,s.sequence_B2,s.sequence_B3})), ...
                'stt:Settings','Every sequence must start at MidC.');
            assert(isempty(intersect(s.sequence_A(2:3),s.sequence_B1(2:3))), ...
                'stt:Settings','B1 q2/q3 must share no ports with A q2/q3.');
            assert(strcmp(s.sequence_A{1},s.sequence_B2{1}) && ...
                ~strcmp(s.sequence_A{3},s.sequence_B2{3}), ...
                'stt:Settings','B2 must share the first port but change the final port.');
            mirror = containers.Map({'MidR','TopR','BotR','MidC','TopL','BotL','MidL'}, ...
                                    {'MidL','TopL','BotL','MidC','TopR','BotR','MidR'});
            expected = cellfun(@(p)mirror(p),s.sequence_A,'UniformOutput',false);
            assert(isequal(s.sequence_B3,expected), ...
                'stt:Settings','B3 must be the left-right mirror of A.');
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
                'T_third','T_reward','T_error','T_timeout','reward_ul'};
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
                     'WaitForThirdPoke','WaitForRewardPort'};
            for k=1:numel(waits)
                if stt.endedAt(p,waits{k},t), step = k; return; end
            end
            if stt.endedAt(p,'StartInterval',t), step=1; return; end
            if stt.endedAt(p,'SecondPoke',t), step=2; end
        end

        function name = priorWait(p,t)
            name = '';
            waits = {'WaitForFirstPoke','WaitForSecondPoke', ...
                     'WaitForThirdPoke','WaitForRewardPort'};
            for k=1:numel(waits)
                if stt.endedAt(p,waits{k},t), name=waits{k}; return; end
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
