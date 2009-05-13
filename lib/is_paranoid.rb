require 'activerecord'

module IsParanoid
  # Call this in your model to enable all the safety-net goodness
  #
  # Example:
  #
  # class Android < ActiveRecord::Base
  #   is_paranoid
  # end
  #

  def is_paranoid opts = {}
    opts[:field] ||= [:deleted_at, Proc.new{Time.now.utc}, nil]
    class_inheritable_accessor :destroyed_field, :field_destroyed, :field_not_destroyed
    self.destroyed_field, self.field_destroyed, self.field_not_destroyed = opts[:field]

    # This is the real magic. All calls made to this model will append
    # the conditions deleted_at => nil (or whatever your destroyed_field
    # and field_not_destroyed are). All exceptions require using
    # exclusive_scope (see self.delete_all, self.count_with_destroyed,
    # and self.find_with_destroyed defined in the module ClassMethods)
    default_scope :conditions => {destroyed_field => field_not_destroyed}

    # Define a member_with_destroyed method on models which belong_to this one.
    # We find the models which belong_to this one by iterating over the ones of
    # which this one has many or has one, and then iterating over those to find
    # which declare that they belong to this one.
    #
    # NOTE: is_paranoid declaration must follow assocation declarations.
    [:has_many, :has_one].each do |macro|
      self.reflect_on_all_associations(macro).each do |assoc|
        if (a = assoc.klass.reflect_on_all_associations(:belongs_to).detect{ |a| a.class_name == self.class_name })
          assoc.klass.send(
            :include,
            Module.new{                                                   # Example:
              define_method "#{a.name}_with_destroyed" do |*args|         # def android_with_destroyed
                a.klass.first_with_destroyed(                             #   Android.first_with_destroyed(
                  :conditions => {                                        #     :conditions => {
                    a.klass.primary_key =>                                #       :id =>
                      self.send(a.primary_key_name)                       #         self.send(:android_id)
                  }                                                       #     }
                )                                                         #   )
              end                                                         # end
            }
          )
        end
      end
    end

    extend ClassMethods
    include InstanceMethods
  end

  module ClassMethods
    # Actually delete the model, bypassing the safety net. Because
    # this method is called internally by Model.delete(id) and on the
    # delete method in each instance, we don't need to specify those
    # methods separately
    def delete_all conditions = nil
      self.with_exclusive_scope { super conditions }
    end

    # Use update_all with an exclusive scope to restore undo the soft-delete.
    # This bypasses update-related callbacks.
    #
    # By default, restores cascade through associations that are
    # :dependent => :destroy and under is_paranoid. You can prevent restoration
    # of associated models by passing :include_destroyed_dependents => false,
    # for example:
    # Android.restore(:include_destroyed_dependents => false)
    def restore(id, options = {})
      options.reverse_merge!({:include_destroyed_dependents => true})
      with_exclusive_scope do
        update_all(
        "#{destroyed_field} = #{connection.quote(field_not_destroyed)}",
        "id = #{id}"
        )
      end

      if options[:include_destroyed_dependents]
        self.reflect_on_all_associations.each do |association|
          if association.options[:dependent] == :destroy and association.klass.respond_to?(:restore)
            association.klass.find_destroyed_only(:all,
            :conditions => ["#{association.primary_key_name} = ?", id]
            ).each do |model|
              model.restore
            end
          end
        end
      end
    end

    # find_with_destroyed and other blah_with_destroyed and
    # blah_destroyed_only methods are defined here
    def method_missing name, *args
      if name.to_s =~ /^(.*)(_destroyed_only|_with_destroyed)$/ and self.respond_to?($1)
        self.extend(Module.new{
          if $2 == '_with_destroyed'
            # Example:
            # def count_with_destroyed(*args)
            #   self.with_exclusive_scope{ self.send(:count, *args) }
            # end
            define_method name do |*args|
              self.with_exclusive_scope{ self.send($1, *args) }
            end
          else

            # Example:
            # def count_destroyed_only(*args)
            #   self.with_exclusive_scope do
            #     with_scope({:find => { :conditions => ["#{destroyed_field} IS NOT ?", nil] }}) do
            #       self.send(:count, *args)
            #     end
            #   end
            # end
            define_method name do |*args|
              self.with_exclusive_scope do
                with_scope({:find => { :conditions => ["#{self.table_name}.#{destroyed_field} IS NOT ?", field_not_destroyed] }}) do
                  self.send($1, *args)
                end
              end
            end

          end
        })
      self.send(name, *args)
      else
        super(name, *args)
      end
    end
  end

  module InstanceMethods

=begin
    def method_missing name, *args
      # if we're trying for a _____with_destroyed method
      # and we can respond to the _____ method
      # and we have an association by the name of _____
      if name.to_s =~ /^(.*)(_with_destroyed)$/ and
          self.respond_to?($1) and
          (assoc = self.class.reflect_on_all_associations.detect{|a| a.name.to_s == $1})

        parent_klass = Object.module_eval("::#{assoc.class_name}", __FILE__, __LINE__)

        self.class.send(
          :include,
          Module.new{                                 # Example:
            define_method name do |*args|             # def android_with_destroyed
              parent_klass.first_with_destroyed(      #   Android.first_with_destroyed(
                :conditions => {                      #     :conditions => {
                  parent_klass.primary_key =>         #       :id =>
                    self.send(assoc.primary_key_name) #         self.send(:android_id)
                }                                     #     }
              )                                       #   )
            end                                       # end
          }
        )
        self.send(name, *args)
      else
        super(name, *args)
      end
    end
=end

    # Mark the model deleted_at as now.
    def destroy_without_callbacks
      self.class.update_all(
        "#{destroyed_field} = #{self.class.connection.quote(( field_destroyed.respond_to?(:call) ? field_destroyed.call : field_destroyed))}",
        "id = #{self.id}"
      )
    end

    # Override the default destroy to allow us to flag deleted_at.
    # This preserves the before_destroy and after_destroy callbacks.
    # Because this is also called internally by Model.destroy_all and
    # the Model.destroy(id), we don't need to specify those methods
    # separately.
    def destroy
      return false if callback(:before_destroy) == false
      result = destroy_without_callbacks
      callback(:after_destroy)
      result
    end

    # Set deleted_at flag on a model to field_not_destroyed, effectively
    # undoing the soft-deletion.
    def restore(options = {})
      self.class.restore(id, options)
    end

  end

end

ActiveRecord::Base.send(:extend, IsParanoid)
