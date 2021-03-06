var ChangeLockDialog = require('new_dashboard/dialogs/change_lock_view');
var cdb = require('cartodb.js');

describe('new_dashboard/dialogs/change_lock_view', function() {
  describe('given view is instantiated with items with different locked states', function() {
    beforeEach(function() {
      this.items = [
        new cdb.core.Model({ locked: true }),
        new cdb.core.Model({ locked: false })
      ]
    });

    it('should not allow to create a dialog with items that have different locked states', function() {
      var self = this;
      expect(function() {
        new ChangeLockDialog({
          items: self.items
        });
      }).toThrow(new Error('It is assumed that all items have the same locked state, a user should never be able to ' +
        'select a mixed item with current UI. If you get an error with this message something is broken'));
    });

    describe('given trackJS is loaded (production)', function() {
      beforeEach(function() {
        window.trackJs = jasmine.createSpyObj('trackJs', ['track']);
        new ChangeLockDialog({
          items: this.items
        });
      });

      it('should track error', function() {
        expect(window.trackJs.track).toHaveBeenCalledWith('It is assumed that all items have the same locked state, a user should never be able to ' +
        'select a mixed item with current UI. If you get an error with this message something is broken');
      });

      afterEach(function() {
        window.trackJs = undefined;
        delete window.trackJs;
      });
    });
  });

  describe('given a set of unlocked items', function() {
    sharedTestsForASetOfItems({
      lockedInitially: false,
      lockOrUnlockStr: 'Lock'
    });
    
    it('should indicate that lock is a negative action in styles', function() {
      expect(this.innerHTML()).toContain('--negative');
      expect(this.innerHTML()).not.toContain('--positive');
    });
  });
  
  describe('given a set of locked items', function() {
    sharedTestsForASetOfItems({
      lockedInitially: true,
      lockOrUnlockStr: 'Unlock'
    });
    
    it('should indicate that unlock is a positive action in styles', function() {
      expect(this.innerHTML()).toContain('--positive');
      expect(this.innerHTML()).not.toContain('--negative');
    });
  });

  afterEach(function() {
    this.view && this.view.clean();
  });
});


function sharedTestsForASetOfItems(opts) {
  beforeEach(function() {
    this.selectedItems = [
      new cdb.core.Model({ name: '1st', locked: opts.lockedInitially }),
      new cdb.core.Model({ name: '2nd', locked: opts.lockedInitially })
    ];
    this.saves = [];
    this.selectedItems.forEach(function(ds) {
      jqXHR = jasmine.createSpyObj('jqXHR', ['done', 'fail']);
      jqXHR.done.and.returnValue(jqXHR);
      jqXHR.fail.and.returnValue(jqXHR);
      spyOn(ds, 'save').and.returnValue(jqXHR);
      this.saves.push(jqXHR);
    }, this);
    this.view = new ChangeLockDialog({
      items: this.selectedItems,
      contentType: 'datasets'
    });
    this.view.render();
  });

  it('should have no leaks', function() {
    expect(this.view).toHaveNoLeaks();
  });

  it('should render a title with '+ opts.lockOrUnlockStr +'+ name of selected items separated by commas', function() {
    expect(this.innerHTML()).toContain(opts.lockOrUnlockStr +' 1st, 2nd');
  });

  it('should render the lock description', function() {
    expect(this.innerHTML()).toContain('By '+ opts.lockOrUnlockStr.toLowerCase() +'ing');
  });

  describe('and "OK, '+ opts.lockOrUnlockStr +'" button is clicked', function() {
    beforeEach(function() {
      spyOn(this.view, 'close').and.callThrough();
      spyOn(this.view, 'undelegateEvents');
      spyOn(this.view, 'delegateEvents');
      this.view.on('done', function() {
        this.triggeredDoneEvent = true;
      }, this);
      this.view.on('fail', function() {
        this.triggeredFailEvent = true;
      }, this);
      this.view.$('.js-ok').click();
    });


    it('should not have triggered done/fail events (just yet)', function() {
      expect(this.triggeredDoneEvent).toBeFalsy();
      expect(this.triggeredFailEvent).toBeFalsy();
    });

    describe('and while change are in process', function() {
      it('should disable click handler so user cannot click multiple times', function() {
        expect(this.view.undelegateEvents).toHaveBeenCalled();
      });
    });

    describe('and change finishes successfully', function() {
      beforeEach(function() {
        this.saves.forEach(function(save) {
          save.done.calls.argsFor(0)[0]();
        }, this);
      });

      it('should save with locked value inversed', function() {
        this.selectedItems.forEach(function(ds) {
          expect(ds.save.calls.argsFor(0)[0]).toEqual(jasmine.objectContaining({ locked: !opts.lockedInitially}));
        });
      });

      it('should trigger a done event', function() {
        expect(this.triggeredDoneEvent).toBeTruthy();
      });

      it('should delete the dialog', function() {
        expect(this.view.close).toHaveBeenCalled();
      });
    });

    describe('and a set fails', function() {
      beforeEach(function() {
        this.saves[0].fail.calls.argsFor(0)[0]('b0rk it!');
      });

      it('should enable buttons again', function() {
        expect(this.view.delegateEvents).toHaveBeenCalled();
      });

      it('should trigger a fail event', function() {
        expect(this.triggeredFailEvent).toBeTruthy();
      });
      
      it('should leave dialog open', function() {
        expect(this.view.close).not.toHaveBeenCalled();
      });
    });
  });
}
