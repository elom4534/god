"""
Calibration isotonic / Platt — obligatoire avant prod.
"""
from sklearn.isotonic import IsotonicRegression
from sklearn.linear_model import LogisticRegression
import numpy as np

def calibrate_isotonic(y_true, y_prob):
    ir = IsotonicRegression(out_of_bounds="clip")
    ir.fit(y_prob, y_true)
    return ir

def calibrate_platt(y_true, y_prob):
    lr = LogisticRegression()
    lr.fit(np.array(y_prob).reshape(-1,1), y_true)
    return lr

def apply_calibration(calibrator, y_prob):
    if hasattr(calibrator, "predict"):
        return calibrator.predict(np.array(y_prob).reshape(-1,1))
    else:
        return calibrator.predict(y_prob)
