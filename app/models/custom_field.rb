#-- encoding: UTF-8
#-- copyright
# OpenProject is a project management system.
# Copyright (C) 2012-2015 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See doc/COPYRIGHT.rdoc for more details.
#++

class CustomField < ActiveRecord::Base
  include CustomField::OrderStatements

  has_many :custom_values, dependent: :delete_all
  acts_as_list scope: 'type = \'#{self.class}\''
  translates :name, :default_value, :possible_values

  accepts_nested_attributes_for :translations,
                                allow_destroy: true,
                                reject_if: :blank_attributes

  def translations_attributes_with_globalized=(attr)
    ret = self.translations_attributes_without_globalized = (attr)

    # enable globalize to access newly set attributes
    translations.loaded
    # remove previously set translated attributes so that they do not override
    # the ones set here
    globalize.reset
    globalize.stash.clear

    ret
  end

  alias_method_chain :translations_attributes=, :globalized

  validates_presence_of :field_format

  validates :name, presence: true, length: { maximum: 30 }

  validate :uniqueness_of_name_with_scope

  def uniqueness_of_name_with_scope
    taken_names = CustomField.where(type: type)
    taken_names = taken_names.where('id != ?', id) if id
    taken_names = taken_names.map { |cf| cf.read_attribute(:name, locale: I18n.locale) }

    errors.add(:name, :taken) if name.in?(taken_names)
  end

  validates_inclusion_of :field_format, in: Redmine::CustomFieldFormat.available_formats

  validate :validate_presence_of_possible_values

  validate :validate_default_value_in_translations

  validates :min_length, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_length, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :min_length, numericality: { less_than_or_equal_to: :max_length, message: :smaller_than_or_equal_to_max_length }, unless: Proc.new { |cf| cf.max_length.blank? }

  def initialize(attributes = nil)
    super
    self.possible_values ||= []
  end

  before_validation :check_searchability

  # make sure int, float, date, and bool are not searchable
  def check_searchability
    self.searchable = false if %w(int float date bool).include?(field_format)
    true
  end

  def validate_presence_of_possible_values
    if field_format == 'list'
      errors.add(:possible_values, :blank) if self.possible_values.blank?
      errors.add(:possible_values, :invalid) unless self.possible_values.is_a? Array
    end
  end

  # validate default value in every translation available
  def validate_default_value_in_translations
    # it is not possible to determine the validity of a value, when there is no valid format.
    # another validation will take care of adding an error, but here we need to abort
    return nil if field_format.blank?

    required_field = is_required
    self.is_required = false
    translated_locales = (translations.map(&:locale) + self.translated_locales).uniq
    translated_locales.each do |locale|
      I18n.with_locale(locale) do
        v = CustomValue.new(custom_field: self, value: default_value, customized: nil)
        errors.add(:default_value, :invalid) unless v.valid?
      end
    end
    self.is_required = required_field
  end

  def possible_values_options(obj = nil)
    case field_format
    when 'user', 'version'
      if obj.is_a?(Project)
        possible_values_options_in_project(obj)
      elsif obj.try(:project)
        possible_values_options_in_project(obj.project)
      else
        []
      end
    else
      locale = obj if obj.is_a?(String) || obj.is_a?(Symbol)
      attribute = possible_values(locale: locale)
      attribute
    end
  end

  def possible_values_options_in_project(project)
    case field_format
    when 'user'
      project.users.sort.map { |u| [u.to_s, u.id.to_s] }
    when 'version'
      project.versions.sort.map { |u| [u.to_s, u.id.to_s] }
    else
      []
    end
  end

  ##
  # Returns possible values for this custom field.
  # Options may be a customizable, or options suitable for ActiveRecord#read_attribute.
  # Notes: You SHOULD pass a customizable if this CF has a format of user or version.
  #        You MUST NOT pass a customizable if this CF has any other format
  # read_attribute is localized - to get values for a specific locale pass the following options hash
  # locale: <locale (-> :en, :de, ...)>
  def possible_values(obj = nil)
    case field_format
    when 'user', 'version'
      possible_values_options(obj).map(&:last)
    else
      options = obj.nil? ? {} : obj
      read_attribute(:possible_values, options)
    end
  end

  # Makes possible_values accept a multiline string
  def possible_values=(arg)
    if arg.is_a?(Array)
      value = arg.compact.map(&:strip).select { |v| !v.blank? }

      write_attribute(:possible_values, value, {})
    else
      self.possible_values = arg.to_s.split(/[\n\r]+/)
    end
  end

  def cast_value(value)
    casted = nil
    unless value.blank?
      case field_format
      when 'string', 'text', 'list'
        casted = value
      when 'date'
        casted = begin; value.to_date; rescue; nil end
      when 'bool'
        casted = ActiveRecord::Type::Boolean.new.cast(value)
      when 'int'
        casted = value.to_i
      when 'float'
        casted = value.to_f
      when 'user', 'version'
        casted = (value.blank? ? nil : field_format.classify.constantize.find_by(id: value.to_i))
      end
    end
    casted
  end

  def <=>(field)
    position <=> field.position
  end

  def self.customized_class
    name =~ /\A(.+)CustomField\z/
    begin; $1.constantize; rescue nil; end
  end

  # to move in project_custom_field
  def self.for_all(options = {})
    where(is_for_all: true)
      .includes(options[:include])
      .order("#{table_name}.position")
  end

  def self.filter
    where(is_filter: true)
  end

  def accessor_name
    "custom_field_#{id}"
  end

  def type_name
    nil
  end

  def name_locale
    attribute_locale :name, name
  end

  def default_value_locale
    attribute_locale :default_value, default_value
  end

  private

  def attribute_locale(attribute, value)
    locales_for_value = translations.select { |t| t.send(attribute) == value }
                        .map(&:locale)
                        .uniq

    locales_for_value.detect { |l| l == I18n.locale } || locales_for_value.first || I18n.locale
  end

  def blank_attributes(attributes)
    value_keys = attributes.reject { |_k, v| v.blank? }.keys.map(&:to_sym)

    !value_keys.include?(:locale) || (value_keys & translated_attribute_names).size == 0
  end
end

# for the sake of nested attributes it is necessary to redefine possible_values
# the values get set directly on the translations association

class CustomField::Translation < Globalize::ActiveRecord::Translation
  serialize :possible_values

  def possible_values=(arg)
    if arg.is_a?(Array)
      value = arg.compact.map(&:strip).select { |v| !v.blank? }

      write_attribute(:possible_values, value)
    else
      self.possible_values = arg.to_s.split(/[\n\r]+/)
    end
  end
end
