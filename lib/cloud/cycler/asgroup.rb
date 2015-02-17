require 'json'
require 'cloud/cycler/namespace'

# Wrapper around AWS::AutoScaling.
class Cloud::Cycler::ASGroup
  def initialize(task, name)
    @task = task
    @name = name
  end

  # Restart any stopped instances, and resume autoscaling processes.
  def start
    if autoscaling_group.suspended_processes.empty?
      @task.debug { "Scaling group #{@name} already running" }
    else
      start_instances

      @task.unsafe("Resuming #{@name} processes") do
        autoscaling_group.resume_all_processes
      end
    end
  end

  # Suspend the autoscaling processes and either terminate or stop the EC2
  # instances under the autoscaling group.
  def stop(action)
    if autoscaling_group.suspended_processes.empty?
      @task.unsafe("Stopping #{@name} processes") do
        autoscaling_group.suspend_all_processes
      end
      case action
      when :default, :terminate
        terminate_instances
      when :stop
        stop_instances
      else
        raise Cloud::Cycler::TaskFailure.new("Unrecognised autoscaling action #{action}")
      end
    else
      @task.debug { "Scaling group #{@name} already suspended" }
    end
  end

  # Terminate all the EC2 instances under the autoscaling group.
  def terminate_instances
    autoscaling_instances.each do |instance|
      @task.unsafe("Terminating instance #{instance.instance_id}") do
        instance.terminate
      end
    end
  end

  # Stop all the instances under the autoscaling group.
  # Normally, autoscaling instances should be safe to add/remove dynamically.
  # However, systems like CQ require manual intervention to add/remove
  # instances.
  def stop_instances
    autoscaling_instances.each do |instance|
      @task.unsafe("Stopping instance #{instance.instance_id}") do
        instance.stop
      end
    end
  end

  # Restart any stopped EC2 instances under the autoscaling group.
  def start_instances
    autoscaling_instances.each do |instance|
      next if !instance.exists?

      if instance.status == "stopped"
        @task.unsafe("Starting instance #{instance.instance_id}") do
          instance.start if instance.exists? && instance.status == "stopped"
        end
      else
        @task.debug { "Instance #{instance.instance_id} already running" }
      end
    end
  end

  private

  # AWS::AutoScaling object
  def aws_autoscaling
    @aws_autoscaling ||= AWS::AutoScaling.new(:region => @task.region)
  end

  # AWS::AutoScaling::Group object
  def autoscaling_group
    @autoscaling_group ||= aws_autoscaling.groups[@name]
  end

  # AWS::EC2::Instance objects contained by the scaling group.
  def autoscaling_instances
    autoscaling_group.auto_scaling_instances.map(&:ec2_instance)
  end
end
