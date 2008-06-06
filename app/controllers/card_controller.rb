class CardController < ApplicationController
  helper :wagn, :card 
  layout :ajax_or_not
  cache_sweeper :card_sweeper
  before_filter :load_card!, :except => [ :auto_complete_for_card_name, :line, :view, :to_view, :test, :new, :create, 
    :show, :index, :mine, :missing, :new_of_type, :my_name ]
  before_filter :load_card_with_cache, :only => [:line, :view, :to_view ]

  before_filter :edit_ok,   :only=>[ :update, :save_draft, :rollback, :save_draft] 
  before_filter :create_ok, :only=>[ :new, :create ]
  before_filter :remove_ok, :only=>[ :remove ]
  
  caches_action :show, :view

  protected
  def action_fragment_key(options)
    roles_key = User.current_user.all_roles.map(&:id).join('-')
    global_serial = Cache.get('GlobalSerial') #Time.now.to_f }
    key = url_for(options).split('://').last + "/#{roles_key}" + "/#{global_serial}" + 
      "/#{ajax_or_not}"
  end
  
  public
   

  #----------( Special cards )
  
  def index
    if card = CachedCard.get_real('*home')
      redirect_to '/'+ card.content
    else
      redirect_to :controller=>'card',:action=>'show', :id=>Cardname.escape(System.site_name)
    end
  end

  def mine
    redirect_to :controller=>'card',:action=>'show', :id=>Cardname.escape(User.current_user.card.name)
  end

  def my_name                                              
    self.class.layout nil
    render :text=>User.current_user.card.name
    self.class.layout :ajax_or_not
  end

  #----------------( MODIFYING CARDS )
  
  #----------------( creating)                                                               
  def new
    params[:card] ||= {}
    content = params[:card].delete(:content)
    @card = Card.new params[:card]
    if !card.hard_template 
      @card.content = 
        (card.class.superclass.to_s=='Card::Basic' or card.type=='Basic') ? content : strip_tags(content)
    end
    @card.name ||= ''
    
    @card.send(:set_defaults)
    
    if @card.type == 'User'
      redirect_to :controller=>'account', :action=>'invite'
    end
  end
  
  def new_of_type #so we could do /new/<type> shortcut
    params[:card] = {:type => params[:type]}    #FIXME - should check to see if the type is right.
    new
    render :action=>'new'
  end
      
  def create
    warn params.inspect         
    @card = Card.create! params[:card]
    if params[:multi_edit]
      User.as(:admin) if @card.type == 'InvitationRequest'
      @card.multi_update(params[:cards])
    end  
    return render_card_errors(@card) unless @card.errors.empty?
    # double check to prevent infinite redirect loop
    fail "Card creation failed"  unless Card.find_by_name( @card.name )
    # FIXME: it would make the tests nicer if we did a real redirect instead of rjs
    render :update do |page|
      page.redirect_to url_for_page(@card.name)
    end
  end 
  
  #--------------( editing )
  
  def edit 
    if @card.ok?(:edit)
      if params[:card] and @card.type=params[:card][:type]  
        @card.save!
        @card = Card.find(card.id)
      end
    else
      render :action=>'denied', :status=>403
    end
  end
  
  def edit_name
    @old_card = @card.clone
    if !params[:card]
    elsif @card.update_attributes params[:card]
      render_update_slot render_to_string(:action=>'edit')
    elsif @card.errors.on(:confirmation_required) && @card.errors.map {|e,f| e}.uniq.length==1
      @confirm = true   
      @card.confirm_rename=true
      @card.update_link_ins = true
#      render :action=>'edit', :status=>200
    else          
      # don't report confirmation required as error in a case where the interface will let you fix it.
      @card.errors.instance_variable_get('@errors').delete('confirmation_required')
      @request_type='html'
      render_card_errors(@card)
    end
  end
  
  
  def update     
    old_rev_id = params[:card] ? params[:card].delete(:current_revision_id)  : nil
    #warn "old rev id = #{old_rev_id}; current = #{@card.current_revision.id} "
    ##FIXME -- this should be taken care of in transclusions, too.
    if params[:card] and params[:card][:content] and (old_rev_id.to_i != @card.current_revision.id.to_i)
      changes  # FIXME -- this should probably be abstracted?
      @no_changes_header = true
      @changes = render_to_string :action=>'changes' 
      return render( :action=>:edit_conflict )
    end 
    if params[:multi_edit]
      @card.multi_update(params[:cards])
    else
      @card.update_attributes! params[:card]     
    end

    return render_card_errors(@card) unless @card.errors.empty?
    render_update_slot render_to_string(:action=>'view')
  end

  def quick_update
    @card.update_attributes! params[:card]
    @card.errors.empty? ? render(:text=>'Success') : render_errors    
  end

  def save_draft
    @card.save_draft( params[:card][:content] )
    render(:update) do |page|
      page.wagn.messenger.log("saved draft of #{@card.name}")
    end
  end  

  def comment
    raise(Wagn::NotFound,"Action comment should be post with card[:comment]") unless request.post? and params[:card]
    @comment = params[:card][:comment];
    if User.current_user.login == 'anon'
      @author = params[:card][:comment_author]
      session[:comment_author] = @author
      @author = "#{@author} (Not signed in)"
    else
      @author = User.current_user.card.name
    end
    @comment.gsub! /\n/, '<br/>'
    @card.comment = "<hr>#{@comment}<br/><p><em>&nbsp;&nbsp;--#{@author}.....#{Time.now}</em></p>"
    @card.save!   
    view = render_to_string(:action=>'view')
    render_update_slot view
  end

  def rollback
    load_card_and_revision
    @card.update_attributes! :content=>@revision.content
    render :action=>'view'
  end  

  #------------( deleting )

  def remove  
    if params[:card]
      @card.confirm_destroy = params[:card][:confirm_destroy]
    end
    if @card.destroy     
      #dirty hack so we dont redirect to ourself after delete
      session[:return_stack].pop if ( session[:return_stack] and session[:return_stack].last==@card.id )
      render_update_slot do |page,target|
        if @context=="main_1"
          page.wagn.messenger.note "#{@card.name} removed. Redirecting to #{previous_page}..."
          page.redirect_to url_for_page(previous_page)
          flash[:notice] =  "#{@card.name} removed"
        else 
          target.replace %{<div class="faint">#{@card.name} was just removed</div>}
          page.wagn.messenger.note( "#{@card.name} removed. ")  
        end
      end
    elsif @card.errors.on(:confirmation_required)
      render_update_slot render_to_string(:partial=>'confirm_remove')
    else
      render_errors
    end
  end

  #---------( VIEWING CARDS )

  def show
    @card_name = Cardname.unescape(params['id'] || '')
    if (@card_name.nil? or @card_name.empty?) then    
      @card_name = System.site_name
      #@card_name = System.deck_name
    end             
    @card = CachedCard.get(@card_name)
        
    if @card.new_record? && ! @card.phantom?
      action =  Cardtype.createable_cardtypes.empty? ? :missing : :new
      return redirect_to( :action=>action, :params=>{ 'card[name]'=>@card_name } )
    end                                                                                  
    remember_card @card
    # FIXME: I'm sure this is broken now that i've refactored..                               
    respond_to do |format|
      format.html { render :action=>'show' }
      format.json {
        @wadget = true
        render_jsonp :partial =>'card/view', 
          :locals=>{ :card=> @card, :context=>"main",:action=>"view"}
      }
    end
  end

  #---------------( tabs )

  def to_view
    params[:view]='open'
    render_update_slot do |page, target|
      target.update render_to_string(:action=>'view')
#      page << "Wagn.line_to_paragraph(#{slot.selector})"
    end
  end
             
  def to_edit
    render_update_slot do |page, target|
      target.update render_to_string(:action=>'edit')
      page << "Wagn.line_to_paragraph(#{slot.selector})"
    end
  end

  def options
    @extension = card.extension
  end

  def changes
    load_card_and_revision
    @show_diff = (params[:mode] != 'false')
    @previous_revision = @card.previous_revision(@revision)
  end
    
    
    
    
    
    
  #-------- ( MISFIT METHODS )  
    
  ### FIXME -- seems like this should be in the cardname controller  
  def auto_complete_for_card_name
    complete = ''
    params.keys.each do |key|
      complete = params[key] if key.to_s == 'name'
      next unless key.to_s =~ /card|pointer/ 
      complete = params[key].values[0]
    end

    if !params[:id].blank? && (card = Card["#{params[:id].tag_name}+*options"]) && card.type=='Search'
      @items = card.search( :complete=>complete, :limit=>8, :sort=>'alpha')
    else
      @items = Card.search( :complete=>complete, :limit=>8, :sort=>'alpha' )
    end
    render :inline => "<%= auto_complete_result @items, 'name' %>"
  end
  
  # doesn't really seem to fit here.  may want to add new controller if methods accrue?        
  def add_field # for pointers only
    render :partial=>'cardtypes/pointer/field', :locals=>params.merge({:card=>@card})
  end
                                                    
end


=begin  
  def create_template
    @card = Card.create! :name=>@card.name+"+*<>template"
    render_update_slot_element 'template',  
      render_to_string( :inline=>%{<%= get_slot.render(:view, :wrap=>true, :add_javascript=>true ) %>})
  end
=end
